// js/config.js
// Supabase Configuration & Shared Constants for Perpustakaan Digital Kabupaten Blora

export const SUPABASE_URL = 'https://gcyvuytalrsxkeiephbt.supabase.co';
export const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdjeXZ1eXRhbHJzeGtlaWVwaGJ0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODkxNzk1MTUsImV4cCI6MjEwNDc1NTUxNX0.5LpwyZTprvuHaz6DYhJ3cfVh48E6c3z5RY2-QimgDeY';

// Helper: Format to Indonesian string safe HTML escape
export function escapeHtml(string) {
    if (!string && string !== 0) return '';
    return String(string)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
}

// Generate URL slug from library name
export function slugify(text) {
    return text
        .toString()
        .toLowerCase()
        .trim()
        .replace(/\s+/g, '-')        // Replace spaces with -
        .replace(/[^\w\-]+/g, '')    // Remove all non-word chars
        .replace(/\-\-+/g, '-')      // Replace multiple - with single -
        .replace(/^-+/, '')          // Trim - from start of text
        .replace(/-+$/, '');         // Trim - from end of text
}

// Helper: Convert Google Drive File ID / URL to usable direct view / thumbnail link
export function getDriveCoverUrl(fileIdOrUrl) {
    if (!fileIdOrUrl) return null;
    const str = fileIdOrUrl.trim();
    if (str.startsWith('http')) return str;
    // Extract file ID if a full drive share URL was pasted
    const match = str.match(/\/d\/([a-zA-Z0-9_-]+)/) || str.match(/id=([a-zA-Z0-9_-]+)/);
    const id = match ? match[1] : str;
    // Return high quality Google Drive thumbnail view
    return `https://drive.google.com/thumbnail?id=${id}&sz=w600`;
}

// Helper: Convert Google Drive File ID to Embed / Preview URL
export function getDriveEmbedUrl(fileIdOrUrl) {
    if (!fileIdOrUrl) return null;
    const str = fileIdOrUrl.trim();
    if (str.startsWith('http')) {
        if (str.includes('drive.google.com') && !str.includes('/preview')) {
            const match = str.match(/\/d\/([a-zA-Z0-9_-]+)/) || str.match(/id=([a-zA-Z0-9_-]+)/);
            if (match) return `https://drive.google.com/file/d/${match[1]}/preview`;
        }
        return str;
    }
    const match = str.match(/\/d\/([a-zA-Z0-9_-]+)/) || str.match(/id=([a-zA-Z0-9_-]+)/);
    const id = match ? match[1] : str;
    return `https://drive.google.com/file/d/${id}/preview`;
}

// Helper: Upload file to Supabase Storage (fallback / direct upload)
export async function uploadToStorage(supabaseClient, bucketName, file, pathPrefix = 'books') {
    const ext = file.name.split('.').pop();
    const fileName = `${pathPrefix}/${Date.now()}_${Math.random().toString(36).substring(2, 8)}.${ext}`;
    
    const { data, error } = await supabaseClient.storage
        .from(bucketName)
        .upload(fileName, file, {
            cacheControl: '3600',
            upsert: false
        });
        
    if (error) throw error;
    
    const { data: { publicUrl } } = supabaseClient.storage
        .from(bucketName)
        .getPublicUrl(fileName);
        
    return {
        path: fileName,
        publicUrl: publicUrl
    };
}

// Helper: Rekam kunjungan portal / buku (Otomatis untuk umum/tamu & anggota)
export async function recordVisit(supabaseClient, { libraryId = null, page = 'portal', bookId = null } = {}) {
    try {
        if (!supabaseClient) return;

        // 1. Identitas unik anonim per browser/perangkat (UUID)
        let vid = localStorage.getItem('blora_visitor_id');
        if (!vid) {
            vid = 'v_' + (typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : (Math.random().toString(36).substring(2) + Date.now().toString(36)));
            localStorage.setItem('blora_visitor_id', vid);
        }

        // 2. Pembatasan throttle harian per halaman agar refresh tidak spam data
        const todayStr = new Date().toISOString().slice(0, 10);
        const throttleKey = `bv_${libraryId || 'central'}_${page}_${bookId || 'all'}_${todayStr}`;
        if (sessionStorage.getItem(throttleKey)) {
            return; // Kunjungan sudah tercatat dalam sesi hari ini
        }

        // 3. Deteksi apakah pengunjung sedang login sebagai anggota
        let userId = null;
        let isMember = false;
        try {
            const { data } = await supabaseClient.auth.getSession();
            if (data?.session?.user) {
                userId = data.session.user.id;
                isMember = true;
            }
        } catch (_) {}

        // 4. Masukkan log ke tabel library_visits
        const { error } = await supabaseClient
            .from('library_visits')
            .insert({
                library_id: libraryId || null,
                visitor_session_id: vid,
                user_id: userId,
                is_member: isMember,
                page_visited: page,
                book_id: bookId || null,
                user_agent: navigator.userAgent ? navigator.userAgent.substring(0, 255) : null
            });

        if (!error) {
            sessionStorage.setItem(throttleKey, '1');
        }
    } catch (e) {
        // Silent error agar kenyamanan pengunjung membaca tidak terganggu
        console.warn('Visitor tracking note:', e.message);
    }
}
