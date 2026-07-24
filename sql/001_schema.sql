-- =====================================================================
-- SMM-бот для мебельной мастерской: схема базы
-- Запускать один раз на чистой базе.
--   psql "postgres://user:pass@host:5432/dbname" -f sql/001_schema.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- users — кто имеет право писать боту.
-- Воркфлоу один на всех, а всё, что отличается от человека к человеку,
-- лежит здесь и подставляется в промпт и в запросы к Instagram.
-- ---------------------------------------------------------------------
create table if not exists users (
    id                 serial primary key,
    telegram_user_id   bigint      not null unique,
    chat_id            bigint      not null,
    display_name       text,
    role               text        not null default 'manager',  -- admin | manager
    is_active          boolean     not null default true,

    -- настройки бренда: попадают в промпт Gemini
    brand_name         text        not null default '',
    city               text        not null default '',
    tone               text        not null default 'спокойный, предметный, без воды',
    extra_instructions text        not null default '',
    default_hashtags   text        not null default '',

    -- куда публиковать
    ig_user_id         text,
    ig_access_token    text,

    created_at         timestamptz not null default now(),
    updated_at         timestamptz not null default now()
);

comment on column users.role is 'admin видит чужие посты и статистику, manager только свои';
comment on column users.ig_access_token is 'long-lived Page Access Token с правом instagram_content_publish';

-- ---------------------------------------------------------------------
-- post_groups — один будущий пост.
--
-- Жизненный цикл поля status:
--   collecting        фото ещё приходят (первые 10 секунд)
--   generating        группа захвачена, идёт генерация текста
--   pending_approval  текст готов, ждём решения владельца
--   editing           владелец попросил правки
--   approved          одобрено, ждёт публикации (сразу или по расписанию)
--   publishing        публикация в процессе
--   published         готово
--   rejected          отклонено владельцем
--   failed            упало с ошибкой
--
-- group_key собирается как "<chat_id>:<media_group_id или m<message_id>>".
-- Уникальность по нему — это и есть механизм склейки альбома.
-- ---------------------------------------------------------------------
create table if not exists post_groups (
    id                   bigserial primary key,
    group_key            text        not null unique,
    user_id              integer     not null references users (id) on delete cascade,
    chat_id              bigint      not null,

    caption              text        not null default '',   -- подпись владельца к фото
    mode                 text        not null default 'auto', -- auto | case | ad
    status               text        not null default 'collecting',

    post_text            text,
    scheduled_at         timestamptz,                        -- отложенная публикация

    ig_media_id          text,
    ig_permalink         text,
    error                text,

    created_at           timestamptz not null default now(),
    updated_at           timestamptz not null default now()
);

create index if not exists idx_post_groups_status       on post_groups (status);
create index if not exists idx_post_groups_user         on post_groups (user_id, created_at desc);
create index if not exists idx_post_groups_scheduled    on post_groups (scheduled_at)
    where scheduled_at is not null;

-- ---------------------------------------------------------------------
-- post_photos — фотографии одной группы.
--
-- unique (group_id, file_unique_id) — дедупликация: если Telegram по какой-то
-- причине доставит один и тот же кадр дважды, вторая вставка молча отвалится.
-- ---------------------------------------------------------------------
create table if not exists post_photos (
    id             bigserial primary key,
    group_id       bigint      not null references post_groups (id) on delete cascade,
    file_id        text        not null,
    file_unique_id text        not null,
    width          integer,
    height         integer,
    file_size      integer,
    public_url     text,                                    -- ссылка после заливки на хостинг
    created_at     timestamptz not null default now(),
    unique (group_id, file_unique_id)
);

create index if not exists idx_post_photos_group on post_photos (group_id, id);
create index if not exists idx_post_photos_uid   on post_photos (file_unique_id);

-- ---------------------------------------------------------------------
-- post_revisions — история версий текста.
-- Версия 1 это первый черновик, дальше по одной на каждый круг правок.
-- ---------------------------------------------------------------------
create table if not exists post_revisions (
    id          bigserial primary key,
    group_id    bigint      not null references post_groups (id) on delete cascade,
    version     integer     not null,
    post_text   text        not null,
    edit_prompt text,                                        -- что именно попросил поправить владелец
    created_at  timestamptz not null default now(),
    unique (group_id, version)
);

-- ---------------------------------------------------------------------
-- publish_log — что уходило в Instagram и чем закончилось.
-- ---------------------------------------------------------------------
create table if not exists publish_log (
    id          bigserial primary key,
    group_id    bigint,
    user_id     integer,
    status      text        not null,                        -- success | error
    ig_media_id text,
    error       text,
    payload     jsonb,
    created_at  timestamptz not null default now()
);

create index if not exists idx_publish_log_group on publish_log (group_id, created_at desc);

-- ---------------------------------------------------------------------
-- Автоматическое обновление updated_at.
-- ---------------------------------------------------------------------
create or replace function touch_updated_at() returns trigger as $$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_users_touch on users;
create trigger trg_users_touch
    before update on users
    for each row execute function touch_updated_at();

drop trigger if exists trg_post_groups_touch on post_groups;
create trigger trg_post_groups_touch
    before update on post_groups
    for each row execute function touch_updated_at();

-- ---------------------------------------------------------------------
-- Удобное представление для команды /stats и для отладки.
-- ---------------------------------------------------------------------
create or replace view v_post_overview as
select g.id,
       g.group_key,
       u.display_name,
       g.status,
       g.mode,
       left(coalesce(g.post_text, ''), 80) as text_preview,
       (select count(*) from post_photos p where p.group_id = g.id) as photos,
       g.ig_permalink,
       g.created_at
from post_groups g
         join users u on u.id = g.user_id
order by g.created_at desc;
