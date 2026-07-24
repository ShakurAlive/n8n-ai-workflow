-- =====================================================================
-- Миграция 003: несколько аккаунтов, промпты в базе, видео, сторис.
--
-- Запускать ПОСЛЕ 001_schema.sql на существующей базе:
--   psql "postgres://..." -f sql/003_accounts_prompts_media.sql
--
-- Миграция идемпотентна: повторный запуск ничего не сломает.
-- Данные из старой схемы переносятся автоматически.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. ACCOUNTS — один аккаунт Instagram со своим контекстом.
--
-- Раньше настройки бренда и токен лежали прямо в users. Это работало,
-- пока у человека один аккаунт. Теперь «кто пишет боту» и «куда
-- публикуем» — разные сущности: у одного пользователя может быть
-- несколько аккаунтов с разным контентом.
-- ---------------------------------------------------------------------
create table if not exists accounts (
    id                 serial primary key,
    owner_user_id      integer     not null references users (id) on delete cascade,

    title              text        not null,                -- как показывать в боте
    keyword            text        not null,                -- короткое имя для команды /use
    is_active          boolean     not null default true,

    -- контекст бренда: попадает в промпт
    brand_name         text        not null default '',
    city               text        not null default '',
    tone               text        not null default '',
    extra_instructions text        not null default '',
    default_hashtags   text        not null default '',

    -- куда публикуем
    ig_user_id         text,
    ig_access_token    text,
    ig_username        text,                                -- для упоминания в сторис

    -- оформление сторис
    story_headline     text        not null default 'НОВЫЙ ПРОЕКТ',
    story_subline      text        not null default 'подробности в профиле',

    created_at         timestamptz not null default now(),
    updated_at         timestamptz not null default now(),
    unique (owner_user_id, keyword)
);

create index if not exists idx_accounts_owner on accounts (owner_user_id) where is_active;

-- какой аккаунт у пользователя выбран сейчас
alter table users add column if not exists active_account_id integer references accounts (id) on delete set null;

-- ---------------------------------------------------------------------
-- 2. PROMPT_TEMPLATES — промпты живут в базе, а не в нодах.
--
-- kind:
--   draft_photo  первый черновик по фотографиям
--   draft_video  первый черновик по видео
--   edit         переписывание по правкам владельца
--   variant      альтернативный вариант того же поста
--
-- account_id = null означает шаблон по умолчанию для всех аккаунтов.
-- Шаблон конкретного аккаунта имеет приоритет над общим.
--
-- Плейсхолдеры внутри body подставляются функцией render_prompt ниже:
--   {{caption}} {{media_count}} {{brand_name}} {{city}}
--   {{tone}} {{extra}} {{hashtags}} {{post_text}} {{edits}}
-- ---------------------------------------------------------------------
create table if not exists prompt_templates (
    id         serial primary key,
    account_id integer references accounts (id) on delete cascade,
    kind       text        not null,
    body       text        not null,
    version    integer     not null default 1,
    is_active  boolean     not null default true,
    note       text,
    created_at timestamptz not null default now()
);

create unique index if not exists idx_prompt_active
    on prompt_templates (coalesce(account_id, 0), kind)
    where is_active;

-- ---------------------------------------------------------------------
-- 3. Подстановка значений в шаблон — прямо в SQL, без кода в n8n.
-- ---------------------------------------------------------------------
create or replace function render_prompt(template text, vars jsonb) returns text as
$$
declare
    result text := template;
    k      text;
    v      text;
begin
    for k, v in select key, value from jsonb_each_text(vars)
        loop
            result := replace(result, '{{' || k || '}}', coalesce(v, ''));
        end loop;
    return result;
end;
$$ language plpgsql immutable;

comment on function render_prompt is
    'render_prompt(body, ''{"caption":"...","city":"Бишкек"}''::jsonb) заменит {{caption}} и {{city}}';

-- ---------------------------------------------------------------------
-- 4. POST_MEDIA — бывшая post_photos, теперь умеет видео.
-- ---------------------------------------------------------------------
-- Переименование обёрнуто в проверку, иначе повторный запуск упал бы:
-- alter table ... rename не понимает if exists для этого случая.
do
$$
    begin
        if exists (select 1 from information_schema.tables
                   where table_name = 'post_photos' and table_schema = current_schema())
        then
            execute 'alter table post_photos rename to post_media';
        end if;
    end
$$;

alter table post_media add column if not exists media_type text not null default 'photo';
alter table post_media add column if not exists duration integer;
alter table post_media add column if not exists mime_type text;

alter table post_media drop constraint if exists post_media_media_type_check;
alter table post_media add constraint post_media_media_type_check
    check (media_type in ('photo', 'video'));

-- ---------------------------------------------------------------------
-- 5. POST_GROUPS — привязка к аккаунту, шаблону и сторис.
-- ---------------------------------------------------------------------
alter table post_groups add column if not exists account_id integer references accounts (id) on delete set null;
alter table post_groups add column if not exists prompt_template_id integer references prompt_templates (id) on delete set null;
alter table post_groups add column if not exists media_kind text not null default 'photo';  -- photo | video | mixed
alter table post_groups add column if not exists story_media_id text;
alter table post_groups add column if not exists story_published_at timestamptz;

create index if not exists idx_post_groups_account on post_groups (account_id, created_at desc);

-- ---------------------------------------------------------------------
-- 6. Перенос существующих данных: из users делаем первый аккаунт.
-- ---------------------------------------------------------------------
insert into accounts (owner_user_id, title, keyword, brand_name, city, tone,
                      extra_instructions, default_hashtags, ig_user_id, ig_access_token)
select u.id,
       coalesce(nullif(u.brand_name, ''), 'Основной'),
       'main',
       u.brand_name,
       u.city,
       u.tone,
       u.extra_instructions,
       u.default_hashtags,
       u.ig_user_id,
       u.ig_access_token
from users u
where not exists (select 1 from accounts a where a.owner_user_id = u.id);

update users u
set active_account_id = a.id
from accounts a
where a.owner_user_id = u.id
  and u.active_account_id is null;

update post_groups g
set account_id = u.active_account_id
from users u
where u.id = g.user_id
  and g.account_id is null;

-- ---------------------------------------------------------------------
-- 7. Шаблоны промптов по умолчанию (общие для всех аккаунтов).
-- ---------------------------------------------------------------------
insert into prompt_templates (account_id, kind, body, note)
select null,
       'draft_photo',
       $tpl$Ты SMM-редактор бренда «{{brand_name}}» из города {{city}}.
Бренд делает корпусную мебель на заказ: кухни, шкафы, гардеробные.

На вход даны {{media_count}} фотографий ОДНОГО объекта или одной рекламной идеи. Это не разные товары, смотри на них как на единый материал.

Комментарий владельца к фото:
"""
{{caption}}
"""

ШАГ 1. Определи режим.
РЕКЛАМА: если комментарий начинается со слов «реклама», «акция», «оффер», «скидка», либо на фото рекламный макет или баннер, а не готовое изделие.
КЕЙС: во всех остальных случаях.

ШАГ 2. Напиши пост.

Если РЕКЛАМА:
- первая строка это сам оффер, конкретно и без разгона;
- 2-3 предложения: что входит, для кого, чем выгодно;
- условие или срок, если он есть в комментарии;
- сильный призыв к действию.

Если КЕЙС:
- первая строка цепляет деталью, которую видно на фото;
- 3-5 предложений: что за изделие, материалы, фурнитура, решения по хранению и эргономике;
- мягкий призыв написать в Direct за расчётом.

ОБЩИЕ ПРАВИЛА:
1. Факты из комментария владельца важнее того, что видно на фото. Материалы, сроки, цены, район, условия акции переноси дословно.
2. Не выдумывай ничего, чего нет ни на фото, ни в комментарии.
3. Тон: {{tone}}
4. {{extra}}
5. Простой текст. Без markdown и без символов * _ [ ] внутри предложений. Максимум 2-3 эмодзи на весь пост.
6. Не длиннее 1200 знаков вместе с хештегами.
7. Последней строкой 8-12 хештегов через пробел. Обязательно используй эти: {{hashtags}} и добавь несколько по смыслу этой работы.

Верни только готовый текст поста, без пояснений и без кавычек вокруг него.$tpl$,
       'базовый шаблон для фотографий'
where not exists (select 1 from prompt_templates where account_id is null and kind = 'draft_photo');

insert into prompt_templates (account_id, kind, body, note)
select null,
       'draft_video',
       $tpl$Ты SMM-редактор бренда «{{brand_name}}» из города {{city}}.
Бренд делает корпусную мебель на заказ.

На вход дано видео готовой работы длительностью около {{duration}} секунд.

Комментарий владельца:
"""
{{caption}}
"""

Посмотри видео целиком и напиши пост для Instagram Reels.

Требования к тексту:
- первая строка должна работать как подпись под Reels: коротко и цепляюще;
- 2-4 предложения о том, что показано: тип изделия, материалы, механизмы, детали, которые видно в движении (доводчики, подсветка, выдвижные системы);
- если в кадре показан процесс или «до и после» — обыграй это;
- призыв написать в Direct за расчётом.

ОБЩИЕ ПРАВИЛА:
1. Факты из комментария владельца важнее того, что видно в кадре.
2. Не выдумывай размеры и цены.
3. Тон: {{tone}}
4. {{extra}}
5. Простой текст, без markdown, максимум 2-3 эмодзи.
6. Не длиннее 1000 знаков вместе с хештегами.
7. Последней строкой 8-12 хештегов: {{hashtags}} плюс несколько по смыслу.

Верни только текст поста.$tpl$,
       'базовый шаблон для видео и Reels'
where not exists (select 1 from prompt_templates where account_id is null and kind = 'draft_video');

insert into prompt_templates (account_id, kind, body, note)
select null,
       'edit',
       $tpl$Ты редактируешь готовый пост для Instagram бренда «{{brand_name}}».

Текущая версия текста:
"""
{{post_text}}
"""

Правки от владельца:
"""
{{edits}}
"""

Внеси правки. Всё, о чём владелец не просил, оставь как было: не переписывай текст целиком, не меняй факты, не трогай хештеги, если про них ничего не сказано.

Если правка противоречит тому, что было на фото, выполни правку. Владелец знает лучше.

Те же ограничения: простой текст без markdown, не длиннее 1200 знаков, хештеги последней строкой.

Верни только новый текст поста.$tpl$,
       'переписывание по правкам'
where not exists (select 1 from prompt_templates where account_id is null and kind = 'edit');

commit;

-- ---------------------------------------------------------------------
-- Обновлённое представление для отладки.
--
-- Именно drop, а не create or replace: набор колонок изменился, а
-- create or replace view не разрешает менять состав и порядок колонок.
-- ---------------------------------------------------------------------
drop view if exists v_post_overview;

create view v_post_overview as
select g.id,
       g.group_key,
       u.display_name,
       a.title                                                    as account,
       g.status,
       g.media_kind,
       left(coalesce(g.post_text, ''), 80)                        as text_preview,
       (select count(*) from post_media m where m.group_id = g.id) as media_cnt,
       g.ig_permalink,
       g.story_published_at,
       g.created_at
from post_groups g
         join users u on u.id = g.user_id
         left join accounts a on a.id = g.account_id
order by g.created_at desc;

-- ---------------------------------------------------------------------
-- Проверка после миграции
-- ---------------------------------------------------------------------
select u.display_name,
       a.title,
       a.keyword,
       a.ig_username,
       (u.active_account_id = a.id) as is_active_now
from users u
         join accounts a on a.owner_user_id = u.id;

select kind, coalesce(account_id::text, 'общий') as scope, length(body) as size
from prompt_templates
where is_active
order by kind;
