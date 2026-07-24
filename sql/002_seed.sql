-- =====================================================================
-- Первый пользователь. Замените значения на свои и выполните:
--   psql "postgres://user:pass@host:5432/dbname" -f sql/002_seed.sql
--
-- Где взять telegram_user_id и chat_id:
--   напишите @userinfobot в Telegram — он пришлёт ваш Id.
--   Для личного чата telegram_user_id и chat_id совпадают.
-- =====================================================================

insert into users (telegram_user_id,
                   chat_id,
                   display_name,
                   role,
                   brand_name,
                   city,
                   tone,
                   extra_instructions,
                   default_hashtags,
                   ig_user_id,
                   ig_access_token)
values (426400864,                       -- telegram_user_id  ← ваш Id
        426400864,                       -- chat_id           ← обычно тот же
        'Shakur',
        'admin',
        'Мастерская корпусной мебели',   -- brand_name
        'Бишкек',                        -- city
        'спокойный, предметный, без пафоса и штампов',
        'Пиши на русском. Обращение на «вы». Не указывай цены, если их нет в подписи к фото.',
        '#мебельбишкек #кухнибишкек #шкафыбишкек #корпуснаямебель #мебельназаказ',
        'ВСТАВЬТЕ_IG_USER_ID',           -- можно заполнить позже
        'ВСТАВЬТЕ_IG_TOKEN')             -- можно заполнить позже
on conflict (telegram_user_id) do update
    set chat_id            = excluded.chat_id,
        display_name       = excluded.display_name,
        brand_name         = excluded.brand_name,
        city               = excluded.city,
        tone               = excluded.tone,
        extra_instructions = excluded.extra_instructions,
        default_hashtags   = excluded.default_hashtags;

-- Проверка
select id, telegram_user_id, display_name, role, brand_name, city
from users;
