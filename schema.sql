-- ============================================================
-- 竹島水族館フォトコンテスト 本番DBスキーマ
-- 1プロジェクト多イベント対応
-- ============================================================

-- ============================================================
-- 1. events: イベントマスター
-- ============================================================
CREATE TABLE events (
  id text PRIMARY KEY,                    -- 'takeshima_2026_summer' のような任意ID
  name text NOT NULL,                     -- イベント表示名
  theme text DEFAULT '',                  -- テーマ文言
  show_theme boolean DEFAULT true,
  show_nickname boolean DEFAULT true,
  show_like_count boolean DEFAULT false,
  bgm_enabled boolean DEFAULT true,
  max_uploads_per_user integer DEFAULT 5,
  slide_interval_seconds integer DEFAULT 5,

  -- 進行
  phase text DEFAULT 'waiting',           -- waiting/voting/result_5..1/finished
  rankings_frozen jsonb,                  -- 結果発表時に凍結したランキング

  -- スケジュール
  upload_schedule jsonb DEFAULT '{"mode":"none","start":null,"end":null}'::jsonb,
  vote_schedule jsonb DEFAULT '{"mode":"none","start":null,"end":null}'::jsonb,
  result_schedule jsonb DEFAULT '{"mode":"none","at":null}'::jsonb,
  schedule_action text DEFAULT 'auto',

  -- 個人情報設定
  identifier_fields jsonb DEFAULT '[]'::jsonb,         -- ['phone','employee_id','email']
  identifier_required boolean DEFAULT true,
  show_privacy_notice boolean DEFAULT true,
  retention_mode text DEFAULT 'auto10',                -- auto10/manual
  host_pin text DEFAULT '',                            -- ホスト用PIN（4桁）
  privacy_policy_url text DEFAULT '',                  -- プライバシーポリシーURL
  terms_url text DEFAULT '',                           -- 利用規約URL

  -- メタ
  host_key text NOT NULL,                              -- 推測困難なホストキー（admin.htmlでの認証）
  status text DEFAULT 'draft',                         -- draft/active/archived
  created_at timestamptz DEFAULT now(),
  ends_at timestamptz                                  -- 自動削除予定日時（auto10の場合）
);

-- ============================================================
-- 2. photos: 投稿写真
-- ============================================================
CREATE TABLE photos (
  id text PRIMARY KEY,
  event_id text NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  user_id text NOT NULL,                  -- ブラウザ生成のID
  nickname text NOT NULL,
  identifiers jsonb DEFAULT '{}'::jsonb,  -- {phone:'...', employee_id:'...', email:'...'}
  image_url text NOT NULL,                -- Storage上のpublic URL
  storage_path text NOT NULL,             -- 削除用のStoragePath
  created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_photos_event ON photos(event_id);
CREATE INDEX idx_photos_event_created ON photos(event_id, created_at DESC);

-- ============================================================
-- 3. likes: いいね（unique制約で重複防止）
-- ============================================================
CREATE TABLE likes (
  id bigserial PRIMARY KEY,
  event_id text NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  photo_id text NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  user_id text NOT NULL,
  created_at timestamptz DEFAULT now(),
  UNIQUE(photo_id, user_id)
);

CREATE INDEX idx_likes_event ON likes(event_id);
CREATE INDEX idx_likes_photo ON likes(photo_id);

-- ============================================================
-- 4. comments: コメント
-- ============================================================
CREATE TABLE comments (
  id text PRIMARY KEY,
  event_id text NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  photo_id text NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  user_id text NOT NULL,
  nickname text NOT NULL,
  text text NOT NULL,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_comments_event ON comments(event_id);
CREATE INDEX idx_comments_photo ON comments(photo_id);

-- ============================================================
-- 5. reports: 通報
-- ============================================================
CREATE TABLE reports (
  id bigserial PRIMARY KEY,
  event_id text NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  photo_id text NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  user_id text NOT NULL,
  created_at timestamptz DEFAULT now(),
  UNIQUE(photo_id, user_id)
);

CREATE INDEX idx_reports_event ON reports(event_id);

-- ============================================================
-- 6. specials: 特別賞
-- ============================================================
CREATE TABLE specials (
  id text PRIMARY KEY,
  event_id text NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  title text DEFAULT '',
  photo_id text REFERENCES photos(id) ON DELETE SET NULL,
  display_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_specials_event ON specials(event_id);

-- ============================================================
-- 7. ランキング集計用ビュー（5位まで＋同点時は新しい投稿が上）
-- ============================================================
CREATE OR REPLACE VIEW photo_rankings AS
SELECT
  p.id,
  p.event_id,
  p.nickname,
  p.image_url,
  p.created_at,
  COALESCE(l.like_count, 0) AS like_count,
  ROW_NUMBER() OVER (
    PARTITION BY p.event_id
    ORDER BY COALESCE(l.like_count, 0) DESC, p.created_at DESC
  ) AS rank_position
FROM photos p
LEFT JOIN (
  SELECT photo_id, COUNT(*) AS like_count
  FROM likes
  GROUP BY photo_id
) l ON p.id = l.photo_id;

-- ============================================================
-- 8. Row Level Security (RLS) ポリシー
-- ============================================================

-- RLSを有効化
ALTER TABLE events ENABLE ROW LEVEL SECURITY;
ALTER TABLE photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE likes ENABLE ROW LEVEL SECURITY;
ALTER TABLE comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE specials ENABLE ROW LEVEL SECURITY;

-- events: 全員SELECT可、INSERT/UPDATE/DELETEは host_key 経由のみ
CREATE POLICY events_select ON events FOR SELECT USING (true);
CREATE POLICY events_insert ON events FOR INSERT WITH CHECK (true);
CREATE POLICY events_update ON events FOR UPDATE USING (true);
-- 注意：本来はhost_keyでの認証が必要。実装ではフロント側でhost_keyを検証する形にする

-- photos: 全員SELECT/INSERT可、ただしidentifiersは取得制限したい
-- 簡易対応：identifiersは初期 SELECT で取得しない設計（Supabase側でカラム指定して取得）
CREATE POLICY photos_select ON photos FOR SELECT USING (true);
CREATE POLICY photos_insert ON photos FOR INSERT WITH CHECK (true);
CREATE POLICY photos_delete ON photos FOR DELETE USING (true);  -- ホスト操作

-- likes: 全員SELECT/INSERT可、自分のレコードのみDELETE
CREATE POLICY likes_select ON likes FOR SELECT USING (true);
CREATE POLICY likes_insert ON likes FOR INSERT WITH CHECK (true);

-- comments: 全員SELECT/INSERT可
CREATE POLICY comments_select ON comments FOR SELECT USING (true);
CREATE POLICY comments_insert ON comments FOR INSERT WITH CHECK (true);

-- reports: 全員SELECT/INSERT可
CREATE POLICY reports_select ON reports FOR SELECT USING (true);
CREATE POLICY reports_insert ON reports FOR INSERT WITH CHECK (true);

-- specials: ホストのみが操作（簡易：全員許可、フロントでhost_key確認）
CREATE POLICY specials_all ON specials FOR ALL USING (true) WITH CHECK (true);

-- ============================================================
-- 9. Realtime対応
-- ============================================================

-- リアルタイム同期するテーブル
ALTER PUBLICATION supabase_realtime ADD TABLE events;
ALTER PUBLICATION supabase_realtime ADD TABLE photos;
ALTER PUBLICATION supabase_realtime ADD TABLE likes;
ALTER PUBLICATION supabase_realtime ADD TABLE comments;
ALTER PUBLICATION supabase_realtime ADD TABLE specials;

-- DELETE時にold_recordを取得するためREPLICA IDENTITY FULLを設定
ALTER TABLE photos REPLICA IDENTITY FULL;
ALTER TABLE likes REPLICA IDENTITY FULL;
ALTER TABLE comments REPLICA IDENTITY FULL;
ALTER TABLE specials REPLICA IDENTITY FULL;

-- ============================================================
-- 10. Storage バケット（管理画面で手動作成 or 以下を実行）
-- ============================================================
-- Storage > Create new bucket
--   Name: photos
--   Public: ON
--
-- またはSQL:
-- INSERT INTO storage.buckets (id, name, public) VALUES ('photos', 'photos', true);
--
-- ポリシー：
-- INSERT/SELECT/DELETE 全て許可（フロント側で event_id 検証）

-- ============================================================
-- 11. 自動削除（個人情報のretention_mode='auto10'対応）
-- ============================================================
-- pg_cron拡張を有効化（Supabaseで対応）
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- 毎日00:00に実行：終了から10日経過したイベントの個人情報をクリア
-- SELECT cron.schedule('clear_pii', '0 0 * * *', $$
--   UPDATE photos
--   SET identifiers = '{}'::jsonb
--   WHERE event_id IN (
--     SELECT id FROM events
--     WHERE retention_mode = 'auto10'
--       AND ends_at IS NOT NULL
--       AND ends_at < now() - INTERVAL '10 days'
--   );
-- $$);

-- ============================================================
-- 12. マイグレーション（既存DBへ後から適用する場合）
-- ============================================================
-- 既にschema.sqlを実行済みで、後からカラムを追加する場合に実行：
-- ALTER TABLE events ADD COLUMN IF NOT EXISTS privacy_policy_url text DEFAULT '';
-- ALTER TABLE events ADD COLUMN IF NOT EXISTS terms_url text DEFAULT '';
