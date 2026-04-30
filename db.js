// ============================================================
// db.js - Supabase接続層
// 全画面（index/admin/events）から共通で使うCRUD/Realtime/Storage処理
// ============================================================

(function() {
  if (!window.SUPABASE_CONFIG || !window.SUPABASE_CONFIG.url || window.SUPABASE_CONFIG.url.includes('YOUR_PROJECT')) {
    console.error('config.js でSupabase接続情報を設定してください');
    alert('config.js でSupabase接続情報を設定してください');
    return;
  }

  const sb = window.supabase.createClient(window.SUPABASE_CONFIG.url, window.SUPABASE_CONFIG.anonKey);
  const BUCKET = window.SUPABASE_CONFIG.bucketName || 'photos';

  // ============================================================
  // Events
  // ============================================================
  async function getEvent(eventId) {
    const { data, error } = await sb.from('events').select('*').eq('id', eventId).maybeSingle();
    if (error) throw error;
    return data;
  }

  async function listEvents() {
    const { data, error } = await sb.from('events').select('*').order('created_at', { ascending: false });
    if (error) throw error;
    return data || [];
  }

  async function createEvent(event) {
    const { data, error } = await sb.from('events').insert(event).select().single();
    if (error) throw error;
    return data;
  }

  async function updateEvent(eventId, patch) {
    const { error } = await sb.from('events').update(patch).eq('id', eventId);
    if (error) throw error;
  }

  async function deleteEvent(eventId) {
    // Storageの写真ファイルも削除（DBはCASCADEで連動削除）
    try {
      const { data: files } = await sb.storage.from(BUCKET).list(eventId, { limit: 1000 });
      if (files && files.length > 0) {
        const paths = files.map(f => `${eventId}/${f.name}`);
        await sb.storage.from(BUCKET).remove(paths);
      }
    } catch (e) {
      console.warn('Storage cleanup warning:', e);
      // Storage削除失敗してもDB削除は続行
    }
    const { error } = await sb.from('events').delete().eq('id', eventId);
    if (error) throw error;
  }

  // ============================================================
  // Photos
  // ============================================================
  async function listPhotos(eventId) {
    // 参加者用：identifiersは取得しない
    const { data, error } = await sb.from('photos')
      .select('id, event_id, user_id, nickname, image_url, storage_path, created_at')
      .eq('event_id', eventId)
      .order('created_at', { ascending: false });
    if (error) throw error;
    return data || [];
  }

  async function listPhotosWithIdentifiers(eventId) {
    // ホスト用：個人情報含む
    const { data, error } = await sb.from('photos')
      .select('*')
      .eq('event_id', eventId)
      .order('created_at', { ascending: false });
    if (error) throw error;
    return data || [];
  }

  async function createPhoto(photo) {
    const { error } = await sb.from('photos').insert(photo);
    if (error) throw error;
  }

  async function deletePhoto(photoId, storagePath) {
    if (storagePath) {
      await sb.storage.from(BUCKET).remove([storagePath]).catch(() => {});
    }
    const { error } = await sb.from('photos').delete().eq('id', photoId);
    if (error) throw error;
  }

  async function countPhotosForUser(eventId, userId) {
    const { count, error } = await sb.from('photos')
      .select('*', { count: 'exact', head: true })
      .eq('event_id', eventId).eq('user_id', userId);
    if (error) throw error;
    return count || 0;
  }

  // ============================================================
  // Storage
  // ============================================================
  async function uploadImage(eventId, blob, fileName) {
    // ファイル名サニタイズ：英数字・記号のみ
    const safeName = (fileName || 'photo.jpg').replace(/[^a-zA-Z0-9._-]/g, '_');
    const path = `${eventId}/${Date.now()}_${Math.random().toString(36).slice(2,8)}_${safeName}`;
    const { error } = await sb.storage.from(BUCKET).upload(path, blob, {
      contentType: blob.type || 'image/jpeg',
      upsert: false,
    });
    if (error) throw error;
    const { data } = sb.storage.from(BUCKET).getPublicUrl(path);
    return { path, publicUrl: data.publicUrl };
  }

  // ============================================================
  // Likes
  // ============================================================
  async function listLikes(eventId) {
    const { data, error } = await sb.from('likes')
      .select('photo_id, user_id')
      .eq('event_id', eventId);
    if (error) throw error;
    return data || [];
  }

  async function addLike(eventId, photoId, userId) {
    const { error } = await sb.from('likes')
      .insert({ event_id: eventId, photo_id: photoId, user_id: userId });
    if (error) {
      if (error.code === '23505') return false;  // unique violation = 既存
      throw error;
    }
    return true;
  }

  // ============================================================
  // Comments
  // ============================================================
  async function listComments(eventId) {
    const { data, error } = await sb.from('comments')
      .select('*')
      .eq('event_id', eventId)
      .order('created_at', { ascending: true });
    if (error) throw error;
    return data || [];
  }

  async function addComment(comment) {
    const { error } = await sb.from('comments').insert(comment);
    if (error) throw error;
  }

  // ============================================================
  // Reports
  // ============================================================
  async function listReports(eventId) {
    const { data, error } = await sb.from('reports')
      .select('photo_id, user_id, created_at')
      .eq('event_id', eventId);
    if (error) throw error;
    return data || [];
  }

  async function addReport(eventId, photoId, userId) {
    const { error } = await sb.from('reports')
      .insert({ event_id: eventId, photo_id: photoId, user_id: userId });
    if (error && error.code !== '23505') throw error;
  }

  async function clearReportsForPhoto(photoId) {
    const { error } = await sb.from('reports').delete().eq('photo_id', photoId);
    if (error) throw error;
  }

  // ============================================================
  // Specials
  // ============================================================
  async function listSpecials(eventId) {
    const { data, error } = await sb.from('specials')
      .select('*')
      .eq('event_id', eventId)
      .order('display_order', { ascending: true });
    if (error) throw error;
    return data || [];
  }

  async function upsertSpecial(special) {
    const { error } = await sb.from('specials').upsert(special);
    if (error) throw error;
  }

  async function deleteSpecial(specialId) {
    const { error } = await sb.from('specials').delete().eq('id', specialId);
    if (error) throw error;
  }

  // ============================================================
  // Realtime
  // ============================================================
  function subscribeEvent(eventId, callbacks) {
    let channel = null;
    let reconnectTimer = null;
    let isConnected = false;

    function connect() {
      channel = sb.channel('event_' + eventId + '_' + Date.now())
        .on('postgres_changes', { event: '*', schema: 'public', table: 'photos', filter: `event_id=eq.${eventId}` },
          (payload) => callbacks.onPhotoChange && callbacks.onPhotoChange(payload))
        .on('postgres_changes', { event: '*', schema: 'public', table: 'likes', filter: `event_id=eq.${eventId}` },
          (payload) => callbacks.onLikeChange && callbacks.onLikeChange(payload))
        .on('postgres_changes', { event: '*', schema: 'public', table: 'comments', filter: `event_id=eq.${eventId}` },
          (payload) => callbacks.onCommentChange && callbacks.onCommentChange(payload))
        .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'events', filter: `id=eq.${eventId}` },
          (payload) => callbacks.onEventChange && callbacks.onEventChange(payload))
        .on('postgres_changes', { event: '*', schema: 'public', table: 'specials', filter: `event_id=eq.${eventId}` },
          (payload) => callbacks.onSpecialChange && callbacks.onSpecialChange(payload))
        .subscribe((status) => {
          if (status === 'SUBSCRIBED') {
            isConnected = true;
            if (callbacks.onConnect) callbacks.onConnect();
          } else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') {
            isConnected = false;
            if (callbacks.onDisconnect) callbacks.onDisconnect();
            // 5秒後に再接続
            if (!reconnectTimer) {
              reconnectTimer = setTimeout(() => {
                reconnectTimer = null;
                if (channel) sb.removeChannel(channel);
                connect();
              }, 5000);
            }
          }
        });
    }

    connect();

    // 制御オブジェクトを返す
    return {
      isConnected: () => isConnected,
      unsubscribe: () => {
        if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
        if (channel) sb.removeChannel(channel);
      },
    };
  }

  function unsubscribe(subscription) {
    // 新APIではsubscribeEventの戻り値オブジェクトのunsubscribeを呼ぶ
    if (subscription && typeof subscription.unsubscribe === 'function') {
      subscription.unsubscribe();
    } else if (subscription) {
      // 互換用：channelオブジェクト直渡し
      try { sb.removeChannel(subscription); } catch (e) {}
    }
  }

  // ============================================================
  // Export
  // ============================================================
  window.DB = {
    sb,
    // Events
    getEvent, listEvents, createEvent, updateEvent, deleteEvent,
    // Photos
    listPhotos, listPhotosWithIdentifiers, createPhoto, deletePhoto, countPhotosForUser,
    // Storage
    uploadImage,
    // Likes
    listLikes, addLike,
    // Comments
    listComments, addComment,
    // Reports
    listReports, addReport, clearReportsForPhoto,
    // Specials
    listSpecials, upsertSpecial, deleteSpecial,
    // Realtime
    subscribeEvent, unsubscribe,
  };
})();
