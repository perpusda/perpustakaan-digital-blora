-- ====================================================================
-- SKRIP LENGKAP PENERAPAN SUPABASE: PERPUSTAKAAN DIGITAL BLORA
-- Menyelesaikan kendala duplikat slug & menyiapkan tabel kunjungan
-- ====================================================================

-- 1. Tambahkan kolom slug jika belum ada
ALTER TABLE public.libraries 
ADD COLUMN IF NOT EXISTS slug text;

-- 2. HAPUS index/constraint lama terlebih dahulu agar tidak menolak pembaruan data kembar
ALTER TABLE public.libraries DROP CONSTRAINT IF EXISTS idx_libraries_slug CASCADE;
DROP INDEX IF EXISTS public.idx_libraries_slug CASCADE;

-- 3. Isi dan buat slug unik untuk SEMUA perpustakaan (data kembar otomatis diberi akhiran -2, -3, dst)
WITH numbered_libs AS (
    SELECT id, 
           COALESCE(
               NULLIF(lower(trim(both '-' from regexp_replace(COALESCE(name, 'perpus'), '[^a-zA-Z0-9]+', '-', 'g'))), ''),
               'perpus'
           ) AS base_slug,
           ROW_NUMBER() OVER (
               PARTITION BY COALESCE(
                   NULLIF(lower(trim(both '-' from regexp_replace(COALESCE(name, 'perpus'), '[^a-zA-Z0-9]+', '-', 'g'))), ''),
                   'perpus'
               )
               ORDER BY id ASC
           ) AS rn
    FROM public.libraries
)
UPDATE public.libraries l
SET slug = CASE 
    WHEN nl.rn = 1 THEN nl.base_slug
    ELSE nl.base_slug || '-' || nl.rn
END
FROM numbered_libs nl
WHERE l.id = nl.id;

-- 4. Buat kembali UNIQUE INDEX (Pasti berhasil karena semua data sudah unik)
CREATE UNIQUE INDEX idx_libraries_slug 
ON public.libraries (slug);

-- 5. Buat Tabel library_visits (Mencatat kunjungan umum/tamu & anggota)
CREATE TABLE IF NOT EXISTS public.library_visits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    library_id UUID REFERENCES public.libraries(id) ON DELETE CASCADE,
    visitor_session_id TEXT NOT NULL,
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    is_member BOOLEAN DEFAULT false,
    page_visited TEXT DEFAULT 'portal',
    book_id UUID REFERENCES public.books(id) ON DELETE SET NULL,
    user_agent TEXT,
    visited_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index agar perhitungan kunjungan (Total, Hari Ini, Bulan Ini) sangat cepat
CREATE INDEX IF NOT EXISTS idx_library_visits_lib_time 
ON public.library_visits (library_id, visited_at);

CREATE INDEX IF NOT EXISTS idx_library_visits_session 
ON public.library_visits (visitor_session_id, visited_at);

-- 6. Row Level Security (RLS) untuk Tabel library_visits
ALTER TABLE public.library_visits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public anonymous can record visits" ON public.library_visits;
CREATE POLICY "Public anonymous can record visits" 
ON public.library_visits FOR INSERT 
TO anon, authenticated
WITH CHECK (true);

DROP POLICY IF EXISTS "Allow select library visits" ON public.library_visits;
CREATE POLICY "Allow select library visits" 
ON public.library_visits FOR SELECT 
TO anon, authenticated 
USING (true);

-- 7. Kebijakan RLS untuk Tabel books (Buku aktif bisa dibaca publik)
ALTER TABLE public.books ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public can view active books" ON public.books;
CREATE POLICY "Public can view active books" 
ON public.books FOR SELECT 
TO anon, authenticated
USING (status = 'ACTIVE');

-- 8. Fungsi & Trigger Pencegahan Eskalasi Role User
CREATE OR REPLACE FUNCTION public.protect_user_role_escalation()
RETURNS trigger AS $$
BEGIN
    IF auth.role() = 'authenticated' THEN
        IF NEW.role IS DISTINCT FROM OLD.role THEN
            IF NOT EXISTS (
                SELECT 1 FROM public.profiles 
                WHERE id = auth.uid() AND role = 'SUPER_ADMIN'
            ) THEN
                RAISE EXCEPTION 'Akses ditolak: Anda tidak memiliki izin untuk mengubah role akun.';
            END IF;
        END IF;

        IF NEW.status IS DISTINCT FROM OLD.status THEN
            IF NOT EXISTS (
                SELECT 1 FROM public.profiles 
                WHERE id = auth.uid() AND role = 'SUPER_ADMIN'
            ) THEN
                RAISE EXCEPTION 'Akses ditolak: Anda tidak memiliki izin untuk mengubah status akun.';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_protect_user_role ON public.profiles;
CREATE TRIGGER trg_protect_user_role
BEFORE UPDATE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.protect_user_role_escalation();

-- 9. Fungsi Pendaftaran Mandiri Perpustakaan (Auto-Collision Safe)
CREATE OR REPLACE FUNCTION public.register_library(
    p_name text,
    p_library_type text,
    p_address text DEFAULT NULL,
    p_village text DEFAULT NULL,
    p_district text DEFAULT NULL,
    p_regency text DEFAULT 'Blora',
    p_phone text DEFAULT NULL,
    p_email text DEFAULT NULL,
    p_admin_name text DEFAULT NULL,
    p_admin_phone text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id uuid;
    v_lib_id uuid;
    v_lib_code text;
    v_slug text;
    v_count int;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Akses ditolak: Pengguna belum terautentikasi.';
    END IF;

    -- Generate slug dasar
    v_slug := lower(trim(both '-' from regexp_replace(p_name, '[^a-zA-Z0-9]+', '-', 'g')));

    -- Jika nama perpustakaan kembar sudah ada, otomatis tambahkan suffix 4 karakter acak
    IF EXISTS (SELECT 1 FROM public.libraries WHERE slug = v_slug) THEN
        v_slug := v_slug || '-' || substr(gen_random_uuid()::text, 1, 4);
    END IF;

    -- Generate kode perpustakaan (LIB-0001, dsb)
    SELECT count(*) + 1 INTO v_count FROM public.libraries;
    v_lib_code := 'LIB-' || lpad(v_count::text, 4, '0');

    -- Insert data perpustakaan
    INSERT INTO public.libraries (
        library_code, name, slug, library_type,
        address, village, district, regency,
        phone, email, status
    ) VALUES (
        v_lib_code, p_name, v_slug, p_library_type,
        p_address, p_village, p_district, p_regency,
        p_phone, p_email, 'ACTIVE'
    )
    RETURNING id INTO v_lib_id;

    -- Update status profile menjadi LIBRARY_ADMIN aktif
    INSERT INTO public.profiles (id, full_name, email, role, status)
    VALUES (v_user_id, p_admin_name, p_email, 'LIBRARY_ADMIN', 'ACTIVE')
    ON CONFLICT (id) DO UPDATE SET
        role = 'LIBRARY_ADMIN',
        status = 'ACTIVE',
        full_name = COALESCE(EXCLUDED.full_name, public.profiles.full_name);

    -- Kaitkan user ke library_admins
    INSERT INTO public.library_admins (user_id, library_id, role, status)
    VALUES (v_user_id, v_lib_id, 'ADMIN', 'ACTIVE')
    ON CONFLICT (user_id, library_id) DO UPDATE SET
        status = 'ACTIVE';

    RETURN json_build_object(
        'library_id', v_lib_id,
        'library_name', p_name,
        'library_code', v_lib_code,
        'slug', v_slug
    );
END;
$$;
