-- =====================================================================
-- Запросы для нод Postgres в n8n.
--
-- Как это работает в n8n:
--   Нода Postgres → Operation: Execute Query
--   В поле "Query" вставляете SQL из блока ниже, как есть, вместе с $1, $2...
--   В Options добавляете "Query Parameters" и вписываете выражение из
--   комментария "ПАРАМЕТРЫ" — это массив значений, который подставится
--   вместо $1, $2 и так далее по порядку.
--
-- Почему $1, а не подстановка текста прямо в SQL:
--   так значения экранируются автоматически. Подпись с кавычкой или
--   апострофом не сломает запрос и не даст сделать SQL-инъекцию.
--
-- Почему в сложных местах используется with ... as (CTE):
--   Postgres не разрешает несколько команд через точку с запятой в одном
--   запросе, если в нём есть параметры $1. Ошибка звучит как
--   "cannot insert multiple commands into a prepared statement".
--   CTE позволяет сделать несколько действий одним запросом.
-- =====================================================================


-- ---------------------------------------------------------------------
-- [1] НАЙТИ ПОЛЬЗОВАТЕЛЯ И ЕГО АКТИВНЫЙ АККАУНТ
-- Нода: «Найти пользователя»
-- ПАРАМЕТРЫ: {{ [ $json.message.from.id ] }}
--
-- Возвращает не только человека, но и аккаунт Instagram, который у него
-- сейчас выбран. Весь контекст бренда приезжает одним запросом.
-- Если запрос вернул 0 строк — доступа нет.
-- ---------------------------------------------------------------------
select u.id                as user_id,
       u.chat_id,
       u.role,
       u.display_name,
       a.id                as account_id,
       a.title             as account_title,
       a.keyword           as account_keyword,
       a.brand_name,
       a.city,
       a.tone,
       a.extra_instructions,
       a.default_hashtags,
       a.ig_user_id,
       a.ig_access_token,
       a.ig_username,
       a.story_headline,
       a.story_subline
from users u
         left join accounts a on a.id = u.active_account_id
where u.telegram_user_id = $1
  and u.is_active = true;


-- ---------------------------------------------------------------------
-- [2] СОЗДАТЬ ИЛИ ОБНОВИТЬ ГРУППУ
-- Нода: «Создать/обновить группу»
-- ПАРАМЕТРЫ: {{ [ $json.group_key, $json.user_id, $json.account_id, $json.chat_id, $json.caption ] }}
--
-- Все файлы альбома выполняют этот запрос почти одновременно. Первый
-- создаёт строку, остальные попадают в do update и обновляют подпись,
-- если она у них есть. За уникальность отвечает ограничение unique
-- внутри самой базы, поэтому гонки нет.
--
-- Подпись в альбоме Telegram цепляет только к первому файлу, поэтому
-- перезаписываем её лишь тогда, когда пришло непустое значение.
-- ---------------------------------------------------------------------
insert into post_groups (group_key, user_id, account_id, chat_id, caption)
values ($1, $2, $3, $4, $5)
on conflict (group_key) do update
    set caption    = case
                         when excluded.caption <> '' then excluded.caption
                         else post_groups.caption
        end,
        updated_at = now()
returning id, status, caption;


-- ---------------------------------------------------------------------
-- [3] ДОБАВИТЬ ФАЙЛ В ГРУППУ
-- Нода: «Добавить медиа»
-- ПАРАМЕТРЫ: {{ [ $json.group_id, $json.file_id, $json.file_unique_id,
--                 $json.width, $json.height, $json.file_size,
--                 $json.media_type, $json.duration, $json.mime_type ] }}
--
-- on conflict do nothing — это дедупликация. Повторная отправка того же
-- файла в ту же группу просто ничего не сделает.
-- ---------------------------------------------------------------------
insert into post_media (group_id, file_id, file_unique_id, width, height,
                        file_size, media_type, duration, mime_type)
values ($1, $2, $3, $4, $5, $6, $7, $8, $9)
on conflict (group_id, file_unique_id) do nothing
returning id;


-- ---------------------------------------------------------------------
-- [4] ЗАХВАТИТЬ ГРУППУ  ← самый важный запрос во всём проекте
-- Нода: «Захватить группу»
-- ПАРАМЕТРЫ: {{ [ $json.group_key ] }}
-- ВАЖНО: у ноды должна быть ВЫКЛЮЧЕНА галочка Always Output Data.
--
-- После паузы все выполнения (по одному на каждый файл) одновременно
-- выполняют этот UPDATE. Postgres обрабатывает их строго по очереди,
-- поэтому условие status = 'collecting' окажется истинным ровно для
-- одного. Оно и получит строку, остальные получат пустой результат
-- и остановятся: в n8n нода с нулём элементов не пускает поток дальше.
--
-- Заодно вычисляем media_kind — от него зависит и промпт, и способ
-- публикации (Reels для видео, карусель для нескольких фото).
-- ---------------------------------------------------------------------
update post_groups g
set status     = 'generating',
    media_kind = (select case
                             when count(*) filter (where m.media_type = 'video') = 0 then 'photo'
                             when count(*) filter (where m.media_type = 'photo') = 0 then 'video'
                             else 'mixed'
                             end
                  from post_media m
                  where m.group_id = g.id),
    updated_at = now()
where g.group_key = $1
  and g.status = 'collecting'
returning *;


-- ---------------------------------------------------------------------
-- [5] ФАЙЛЫ, НАСТРОЙКИ АККАУНТА И ГОТОВЫЙ ПРОМПТ
-- Нода: «Медиа и настройки»
-- ПАРАМЕТРЫ: {{ [ $json.id ] }}          (id группы из запроса [4])
--
-- Здесь происходит главное для мультиаккаунтности: промпт берётся из
-- таблицы prompt_templates и уже отрендеренным приезжает в поле prompt.
-- Нода Gemini получает просто {{ $json.prompt }} и ничего не знает
-- ни про бренды, ни про режимы.
--
-- Выбор шаблона: сначала ищем шаблон конкретного аккаунта, если его нет —
-- берём общий (account_id is null). Вид шаблона зависит от того, фото
-- в группе или видео.
-- ---------------------------------------------------------------------
with grp as (select g.id,
                    g.chat_id,
                    g.caption,
                    g.media_kind,
                    g.account_id,
                    a.brand_name,
                    a.city,
                    a.tone,
                    a.extra_instructions,
                    a.default_hashtags,
                    a.ig_user_id,
                    a.ig_access_token,
                    a.ig_username,
                    a.story_headline,
                    a.story_subline
             from post_groups g
                      join accounts a on a.id = g.account_id
             where g.id = $1),
     stats as (select count(*)                as media_count,
                      coalesce(max(duration), 0) as duration
               from post_media
               where group_id = $1),
     tpl as (select t.id, t.body
             from prompt_templates t,
                  grp
             where t.is_active
               and t.kind = case when grp.media_kind = 'photo' then 'draft_photo' else 'draft_video' end
               and (t.account_id = grp.account_id or t.account_id is null)
             order by t.account_id nulls last
             limit 1)
select m.id        as media_id,
       m.file_id,
       m.file_unique_id,
       m.media_type,
       m.duration,
       m.public_url,
       grp.id      as group_id,
       grp.chat_id,
       grp.caption,
       grp.media_kind,
       grp.account_id,
       grp.brand_name,
       grp.city,
       grp.tone,
       grp.extra_instructions,
       grp.default_hashtags,
       grp.ig_user_id,
       grp.ig_access_token,
       grp.ig_username,
       grp.story_headline,
       grp.story_subline,
       stats.media_count,
       tpl.id      as prompt_template_id,
       render_prompt(tpl.body, jsonb_build_object(
               'caption', coalesce(nullif(grp.caption, ''), '(комментария не было)'),
               'media_count', stats.media_count::text,
               'duration', stats.duration::text,
               'brand_name', grp.brand_name,
               'city', grp.city,
               'tone', grp.tone,
               'extra', grp.extra_instructions,
               'hashtags', grp.default_hashtags
                             )) as prompt
from post_media m,
     grp,
     stats,
     tpl
where m.group_id = grp.id
order by m.id;


-- ---------------------------------------------------------------------
-- [6] ПРОВЕРКА НА ПОВТОР (опционально)
-- ПАРАМЕТРЫ: {{ [ $json.file_unique_ids ] }}   — массив строк
-- ---------------------------------------------------------------------
select m.file_unique_id,
       g.id as published_in_group,
       g.ig_permalink
from post_media m
         join post_groups g on g.id = m.group_id
where g.status = 'published'
  and m.file_unique_id = any ($1::text[]);


-- ---------------------------------------------------------------------
-- [7] СОХРАНИТЬ ПУБЛИЧНЫЙ URL ФАЙЛА
-- Нода: «Сохранить URL»
-- ПАРАМЕТРЫ: {{ [ $json.public_url, $json.media_id ] }}
-- ---------------------------------------------------------------------
update post_media
set public_url = $1
where id = $2
returning id, public_url;


-- ---------------------------------------------------------------------
-- [8] СОХРАНИТЬ ТЕКСТ ПОСТА И ЗАПИСАТЬ ВЕРСИЮ
-- Ноды: «Сохранить текст» и «Сохранить правку»
-- ПАРАМЕТРЫ: {{ [ group_id, post_text, edit_prompt, prompt_template_id ] }}
--
-- Финальный select нужен не для красоты: после него все ноды ниже читают
-- текст из базы, а не из выхода Gemini. Это важно из-за цикла правок —
-- при повторном заходе текст берётся свежий, и ссылки на ноды не путаются.
-- ---------------------------------------------------------------------
with upd as (
    update post_groups
        set post_text = $2,
            status = 'pending_approval',
            prompt_template_id = coalesce($4::int, prompt_template_id),
            updated_at = now()
        where id = $1
        returning id, chat_id, post_text, caption, user_id, account_id),
     rev as (
         insert into post_revisions (group_id, version, post_text, edit_prompt)
             select upd.id,
                    (select coalesce(max(version), 0) + 1 from post_revisions where group_id = $1),
                    $2,
                    nullif($3, '')
             from upd
             returning version)
select upd.id                    as group_id,
       upd.chat_id,
       upd.post_text,
       upd.caption,
       a.brand_name,
       (select version from rev) as version
from upd
         left join accounts a on a.id = upd.account_id;


-- ---------------------------------------------------------------------
-- [8b] ПРОМПТ ДЛЯ ПРАВОК
-- Нода: «Промпт для правок»
-- ПАРАМЕТРЫ: {{ [ $json.group_id, $json.edits ] }}
--
-- Тот же механизм, что и с первым черновиком: текст промпта приходит
-- из базы уже готовым, нода Gemini получает {{ $json.prompt }}.
-- ---------------------------------------------------------------------
with grp as (select g.id, g.post_text, g.account_id, a.brand_name
             from post_groups g
                      join accounts a on a.id = g.account_id
             where g.id = $1),
     tpl as (select t.id, t.body
             from prompt_templates t,
                  grp
             where t.is_active
               and t.kind = 'edit'
               and (t.account_id = grp.account_id or t.account_id is null)
             order by t.account_id nulls last
             limit 1)
select grp.id  as group_id,
       tpl.id  as prompt_template_id,
       render_prompt(tpl.body, jsonb_build_object(
               'brand_name', grp.brand_name,
               'post_text', grp.post_text,
               'edits', $2
                             )) as prompt
from grp,
     tpl;


-- ---------------------------------------------------------------------
-- [9] ПОМЕТИТЬ ГРУППУ КАК ПУБЛИКУЕМУЮ
-- Нода: «Захватить публикацию»
-- ПАРАМЕТРЫ: {{ [ $json.group_id ] }}
-- ВАЖНО: Always Output Data выключена.
--
-- Такой же приём, как в [4]: защищает от двойной публикации, если
-- кнопку нажали дважды или воркфлоу перезапустили.
-- ---------------------------------------------------------------------
update post_groups
set status     = 'publishing',
    updated_at = now()
where id = $1
  and status in ('pending_approval', 'approved')
returning *;


-- ---------------------------------------------------------------------
-- [9b] ДАННЫЕ ДЛЯ ПУБЛИКАЦИИ
-- Нода: «Данные для публикации»
-- ПАРАМЕТРЫ: {{ [ $json.id ] }}
--
-- Отдельной нодой, а не одним запросом с [9]: если [9] вернул ноль строк,
-- выполнение обязано остановиться. Склей мы их вместе, select всё равно
-- вернул бы строку, и защита от двойной публикации перестала бы работать.
-- ---------------------------------------------------------------------
select g.id      as group_id,
       g.chat_id,
       g.post_text,
       g.media_kind,
       a.ig_user_id,
       a.ig_access_token,
       a.ig_username,
       a.story_headline,
       a.story_subline
from post_groups g
         join accounts a on a.id = g.account_id
where g.id = $1;


-- ---------------------------------------------------------------------
-- [10] ОТМЕТИТЬ УСПЕШНУЮ ПУБЛИКАЦИЮ
-- Нода: «Отметить опубликованным»
-- ПАРАМЕТРЫ: {{ [ group_id, ig_media_id, ig_permalink ] }}
-- ---------------------------------------------------------------------
with upd as (
    update post_groups
        set status = 'published',
            ig_media_id = $2,
            ig_permalink = $3,
            error = null,
            updated_at = now()
        where id = $1
        returning id, user_id),
     logged as (
         insert into publish_log (group_id, user_id, status, ig_media_id)
             select id, user_id, 'success', $2
             from upd
             returning id)
select upd.id                  as group_id,
       (select id from logged) as log_id
from upd;


-- ---------------------------------------------------------------------
-- [11] ОТМЕТИТЬ ОШИБКУ
-- Нода: «Записать ошибку»
-- ПАРАМЕТРЫ: {{ [ group_id, error_text ] }}
-- ---------------------------------------------------------------------
with upd as (
    update post_groups
        set status = 'failed',
            error = $2,
            updated_at = now()
        where id = $1
        returning id, user_id),
     logged as (
         insert into publish_log (group_id, user_id, status, error)
             select id, user_id, 'error', $2
             from upd
             returning id)
select upd.id                  as group_id,
       (select id from logged) as log_id
from upd;


-- ---------------------------------------------------------------------
-- [12] ОТКЛОНИТЬ ЧЕРНОВИК
-- ПАРАМЕТРЫ: {{ [ group_id ] }}
-- ---------------------------------------------------------------------
update post_groups
set status     = 'rejected',
    updated_at = now()
where id = $1
returning id;


-- ---------------------------------------------------------------------
-- [13] ПОСТАВИТЬ В ОЧЕРЕДЬ НА ОТЛОЖЕННУЮ ПУБЛИКАЦИЮ
-- ПАРАМЕТРЫ: {{ [ group_id, scheduled_at ] }}
-- scheduled_at строкой ISO, например {{ $now.plus(8, 'hours').toISO() }}
-- ---------------------------------------------------------------------
update post_groups
set status       = 'approved',
    scheduled_at = $2::timestamptz,
    updated_at   = now()
where id = $1
returning id, scheduled_at;


-- ---------------------------------------------------------------------
-- [14] ЧТО ПОРА ПУБЛИКОВАТЬ  (воркфлоу с расписанием)
-- ПАРАМЕТРОВ НЕТ
-- ---------------------------------------------------------------------
select g.id as group_id
from post_groups g
where g.status = 'approved'
  and g.scheduled_at is not null
  and g.scheduled_at <= now()
order by g.scheduled_at
limit 5;


-- ---------------------------------------------------------------------
-- [15] ПУБЛИЧНЫЕ URL ФАЙЛОВ ДЛЯ INSTAGRAM
-- Нода: «URL медиа»
-- ПАРАМЕТРЫ: {{ [ group_id ] }}
-- ---------------------------------------------------------------------
select id as media_id,
       public_url,
       media_type,
       duration
from post_media
where group_id = $1
  and public_url is not null
order by id;


-- ---------------------------------------------------------------------
-- [16] СТАТИСТИКА ДЛЯ КОМАНДЫ /stats
-- ПАРАМЕТРЫ: {{ [ user_id ] }}
-- ---------------------------------------------------------------------
select coalesce(a.title, 'без аккаунта') as account,
       g.status,
       count(*)                          as cnt
from post_groups g
         left join accounts a on a.id = g.account_id
where g.user_id = $1
  and g.created_at > now() - interval '30 days'
group by 1, 2
order by cnt desc;


-- ---------------------------------------------------------------------
-- [17] АККАУНТЫ ПОЛЬЗОВАТЕЛЯ ДЛЯ КОМАНДЫ /brand
-- ПАРАМЕТРЫ: {{ [ user_id ] }}
-- ---------------------------------------------------------------------
select a.keyword,
       a.title,
       a.brand_name,
       a.city,
       a.tone,
       a.default_hashtags,
       coalesce(a.ig_username, '(не задан)')     as ig_username,
       (u.active_account_id = a.id)              as is_active
from accounts a
         join users u on u.id = a.owner_user_id
where a.owner_user_id = $1
  and a.is_active
order by a.id;


-- ---------------------------------------------------------------------
-- [18] ПЕРЕКЛЮЧИТЬ АКТИВНЫЙ АККАУНТ  (команда /use кухни)
-- Нода: «Переключить аккаунт»
-- ПАРАМЕТРЫ: {{ [ user_id, keyword ] }}
--
-- Если такого keyword у пользователя нет, вернётся ноль строк и ветка
-- остановится — на этот случай в воркфлоу стоит IF с подсказкой.
-- ---------------------------------------------------------------------
with target as (select id, title
                from accounts
                where owner_user_id = $1
                  and lower(keyword) = lower($2)
                  and is_active
                limit 1)
update users u
set active_account_id = target.id
from target
where u.id = $1
returning target.title as account_title, target.id as account_id;


-- ---------------------------------------------------------------------
-- [19] УБОРКА ЗАВИСШИХ ГРУПП  (по расписанию раз в час)
-- ПАРАМЕТРОВ НЕТ
-- ---------------------------------------------------------------------
update post_groups
set status = 'failed',
    error  = 'зависло в статусе generating дольше 30 минут'
where status = 'generating'
  and updated_at < now() - interval '30 minutes'
returning id, group_key;


-- ---------------------------------------------------------------------
-- [20] ОТМЕТИТЬ ОПУБЛИКОВАННУЮ СТОРИС
-- Нода: «Отметить сторис»
-- ПАРАМЕТРЫ: {{ [ group_id, story_media_id ] }}
-- ---------------------------------------------------------------------
update post_groups
set story_media_id     = $2,
    story_published_at = now(),
    updated_at         = now()
where id = $1
returning id, story_media_id;


-- ---------------------------------------------------------------------
-- [21] КАРТИНКА-ОБЛОЖКА ДЛЯ СТОРИС
-- Нода: «Обложка для сторис»
-- ПАРАМЕТРЫ: {{ [ group_id ] }}
--
-- Берём первый файл группы. Для видео сторис нужен отдельный ролик,
-- поэтому для видеопостов сторис делаем из обложки: у Cloudinary
-- есть трансформация, которая достаёт кадр из видео.
-- ---------------------------------------------------------------------
select m.public_url,
       m.media_type,
       g.ig_permalink,
       a.ig_username,
       a.story_headline,
       a.story_subline,
       a.ig_user_id,
       a.ig_access_token,
       g.chat_id,
       g.id as group_id
from post_media m
         join post_groups g on g.id = m.group_id
         join accounts a on a.id = g.account_id
where m.group_id = $1
  and m.public_url is not null
order by m.id
limit 1;
