// Handle Message: обработка входящих сообщений (фото-альбомы + правка текста)
const bot = $env.TELEGRAM_BOT_TOKEN;
const H = this.helpers;
const { Client } = require('pg');
const sd = $getWorkflowStaticData('global');
const m = $input.first().json.message;
if (!m) { return []; }
const chatId = m.chat.id;

const client = new Client();
await client.connect();
try {
  await client.query(`CREATE TABLE IF NOT EXISTS tg_albums (
    gid text PRIMARY KEY,
    chat_id bigint NOT NULL,
    file_ids text[] NOT NULL DEFAULT '{}',
    caption text NOT NULL DEFAULT '',
    updated_at timestamptz NOT NULL DEFAULT now()
  )`);
  await client.query(`CREATE TABLE IF NOT EXISTS posts (
    id bigserial PRIMARY KEY,
    chat_id bigint NOT NULL,
    caption text NOT NULL,
    file_ids text[] NOT NULL,
    status text NOT NULL DEFAULT 'draft',
    publish_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
  )`);

  // --- Режим редактирования: пришёл новый текст поста ---
  if (sd.editing && sd.editing[chatId] && m.text && !m.photo) {
    const pid = sd.editing[chatId];
    delete sd.editing[chatId];
    const newCap = String(m.text).trim();
    const up = await client.query('UPDATE posts SET caption = $1 WHERE id = $2 RETURNING file_ids', [newCap, pid]);
    if (up.rows.length) {
      const fids = up.rows[0].file_ids || [];
      if (fids.length === 1) {
        await H.httpRequest({ method: 'POST', url: `https://api.telegram.org/bot${bot}/sendPhoto`, body: { chat_id: chatId, photo: fids[0] }, json: true });
      } else if (fids.length > 1) {
        await H.httpRequest({ method: 'POST', url: `https://api.telegram.org/bot${bot}/sendMediaGroup`, body: { chat_id: chatId, media: fids.slice(0, 10).map((id) => ({ type: 'photo', media: id })) }, json: true });
      }
      const kb = [
        [{ text: '✅ Опубликовать', callback_data: 'approve:' + pid }, { text: '⏰ Запланировать', callback_data: 'sched:' + pid }],
        [{ text: '✏️ Отредактировать', callback_data: 'edit:' + pid }, { text: '❌ Отклонить', callback_data: 'reject:' + pid }]
      ];
      await H.httpRequest({ method: 'POST', url: `https://api.telegram.org/bot${bot}/sendMessage`, body: { chat_id: chatId, text: 'Обновлённый черновик:\n\n' + newCap + '\n\nЧто делаем?', reply_markup: { inline_keyboard: kb } }, json: true });
    }
    return [];
  }

  // --- Накопление фото альбома (атомарно через Postgres) ---
  if (!m.photo) { return []; }
  const gid = String(m.media_group_id || ('single_' + m.message_id));
  const largest = m.photo[m.photo.length - 1];
  const cap = m.caption || '';
  await client.query(
    `INSERT INTO tg_albums (gid, chat_id, file_ids, caption, updated_at)
     VALUES ($1, $2, ARRAY[$3], $4, now())
     ON CONFLICT (gid) DO UPDATE SET
       file_ids = array_append(tg_albums.file_ids, $3),
       caption = CASE WHEN $4 <> '' THEN $4 ELSE tg_albums.caption END,
       updated_at = now()`,
    [gid, chatId, largest.file_id, cap]
  );
  return [{ json: { gid } }];
} finally {
  await client.end();
}
