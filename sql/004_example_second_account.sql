-- =====================================================================
-- Пример: второй аккаунт Instagram со своим промптом.
--
-- Запускать не обязательно. Это образец, по которому вы будете
-- добавлять новые аккаунты. Скопируйте, поменяйте значения, выполните.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Сам аккаунт.
-- keyword — то, что вы будете писать боту: /use kitchens
-- ---------------------------------------------------------------------
insert into accounts (owner_user_id, title, keyword,
                      brand_name, city, tone, extra_instructions, default_hashtags,
                      ig_user_id, ig_access_token, ig_username,
                      story_headline, story_subline)
select u.id,
       'Кухни',                                       -- как показывать в списке /brand
       'kitchens',                                    -- ключ для /use
       'Кухни на заказ',                              -- бренд в промпте
       'Бишкек',
       'тёплый, домашний, без канцелярита',
       'Всегда упоминай, что замер бесплатный.',      -- дополнительная инструкция
       '#кухнибишкек #кухнюназаказ #мебельбишкек',
       'ВСТАВЬТЕ_IG_USER_ID',
       'ВСТАВЬТЕ_ДОЛГОЖИВУЩИЙ_ТОКЕН',
       'вашюзернейм',                                 -- без @, попадёт на обложку сторис
       'НОВАЯ КУХНЯ',                                 -- крупная надпись на сторис
       'замер бесплатно — пишите в Direct'            -- подпись помельче
from users u
where u.telegram_user_id = 000000000                  -- ваш Telegram ID
on conflict (owner_user_id, keyword) do update
    set title              = excluded.title,
        brand_name         = excluded.brand_name,
        city               = excluded.city,
        tone               = excluded.tone,
        extra_instructions = excluded.extra_instructions,
        default_hashtags   = excluded.default_hashtags,
        ig_user_id         = excluded.ig_user_id,
        ig_access_token    = excluded.ig_access_token,
        ig_username        = excluded.ig_username,
        story_headline     = excluded.story_headline,
        story_subline      = excluded.story_subline,
        updated_at         = now();

-- ---------------------------------------------------------------------
-- 2. Свой промпт только для этого аккаунта.
--
-- Общий шаблон из миграции 003 остаётся на месте и работает для всех
-- остальных аккаунтов. Запрос выбирает шаблон аккаунта, если он есть,
-- и падает обратно на общий, если его нет.
--
-- Прежде чем вставить новый шаблон, гасим старый: уникальный индекс
-- разрешает только один активный шаблон каждого вида на аккаунт.
-- ---------------------------------------------------------------------
update prompt_templates t
set is_active = false
from accounts a
where a.keyword = 'kitchens'
  and t.account_id = a.id
  and t.kind = 'draft_photo';

insert into prompt_templates (account_id, kind, body, note)
select a.id,
       'draft_photo',
       $tpl$Ты пишешь для Instagram студии «{{brand_name}}» из города {{city}}.
Аккаунт только про кухни, других изделий тут не бывает.

На вход {{media_count}} фотографий одной кухни.

Комментарий владельца:
"""
{{caption}}
"""

Напиши пост так:
- первая строка про то, что цепляет в этой кухне: цвет фасадов, планировка, необычное решение;
- дальше 3-4 предложения: материал фасадов и корпуса, столешница, фурнитура, что решили с хранением и рабочим треугольником;
- если в комментарии есть метраж, район или сроки, обязательно их назови;
- заверши приглашением на бесплатный замер.

Ограничения:
- тон: {{tone}}
- {{extra}}
- простой текст без markdown, максимум 2 эмодзи;
- до 1100 знаков;
- последней строкой хештеги: {{hashtags}} плюс 4-5 по смыслу этой работы.

Верни только текст поста.$tpl$,
       'узкий шаблон под аккаунт с кухнями'
from accounts a
where a.keyword = 'kitchens';

-- ---------------------------------------------------------------------
-- Проверка
-- ---------------------------------------------------------------------
select a.keyword,
       a.title,
       t.kind,
       case when t.account_id is null then 'общий' else 'свой' end as prompt_scope
from accounts a
         left join prompt_templates t
                   on (t.account_id = a.id or t.account_id is null) and t.is_active
order by a.keyword, t.kind;
