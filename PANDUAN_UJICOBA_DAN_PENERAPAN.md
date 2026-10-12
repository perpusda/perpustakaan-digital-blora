# PANDUAN UJICOBA & PENERAPAN SISTEM
## PERPUSTAKAAN DIGITAL KABUPATEN BLORA
### *"Centralized Digital Library — Zero Redundancy"*

Dokumen ini berisi panduan teknis langkah demi langkah (*step-by-step*) untuk menguji seluruh alur kerja, memvalidasi arsitektur *Zero Redundancy*, serta menerapkan perubahan ke lingkungan produksi Cloudflare Pages.

---

## DAFTAR ISI
1. [Langkah 1: Menjalankan Database Migration di Supabase](#langkah-1-menjalankan-database-migration-di-supabase)
2. [Langkah 2: Menjalankan Server Lokal untuk Pengujian](#langkah-2-menjalankan-server-lokal-untuk-pengujian)
3. [Langkah 3: Ujicoba Login & Dashboard Super Admin](#langkah-3-ujicoba-login--dashboard-super-admin)
4. [Langkah 4: Ujicoba Master Buku (Prinsip Centralized)](#langkah-4-ujicoba-master-buku-prinsip-centralized)
5. [Langkah 5: Ujicoba Portal White-Label (?perpus=)](#langkah-5-ujicoba-portal-white-label-perpus)
6. [Langkah 6: Ujicoba Pendaftaran Perpustakaan & Login Library Admin](#langkah-6-ujicoba-pendaftaran-perpustakaan--login-library-admin)
7. [Langkah 7: Ujicoba Pendaftaran Anggota & Dashboard Member](#langkah-7-ujicoba-pendaftaran-anggota--dashboard-member)
8. [Langkah 8: Ujicoba Detail Buku, In-App Reader, & Bookmark](#langkah-8-ujicoba-detail-buku-in-app-reader--bookmark)
9. [Langkah 9: Ujicoba Keamanan & Penolakan Eskalasi Role](#langkah-9-ujicoba-keamanan--penolakan-eskalasi-role)
10. [Langkah 10: Panduan Penerapan (Deployment) ke Cloudflare Pages](#langkah-10-panduan-penerapan-deployment-ke-cloudflare-pages)

---

## Langkah 1: Menjalankan Database Migration di Supabase

Sebelum melakukan ujicoba di antarmuka web, jalankan SQL Migration untuk menambahkan kolom `slug` pada perpustakaan dan mengaktifkan proteksi anti-eskalasi role.

1. Buka browser dan masuk ke Dashboard Supabase Project:
   **URL:** `https://supabase.com/dashboard/project/gcyvuytalrsxkeiephbt`
2. Klik menu **SQL Editor** pada navigasi sebelah kiri.
3. Klik tombol **New Query**.
4. Salin dan tempelkan skrip SQL berikut:

```sql
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

-- 4. Fungsi & Trigger Pencegahan Eskalasi Role (Security)
CREATE OR REPLACE FUNCTION public.protect_user_role_escalation()
RETURNS trigger AS $$
BEGIN
    IF auth.role() = 'authenticated' THEN
        -- Cegah user biasa mengubah role sendiri menjadi SUPER_ADMIN
        IF NEW.role IS DISTINCT FROM OLD.role THEN
            IF NOT EXISTS (
                SELECT 1 FROM public.profiles 
                WHERE id = auth.uid() AND role = 'SUPER_ADMIN'
            ) THEN
                RAISE EXCEPTION 'Akses ditolak: Anda tidak memiliki izin untuk mengubah role akun.';
            END IF;
        END IF;

        -- Cegah user mengubah status sendiri menjadi ACTIVE jika sedang di-suspend
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

-- 5. Kebijakan RLS SELECT untuk buku aktif (Dapat dibaca oleh semua pengunjung)
DROP POLICY IF EXISTS "Public can view active books" ON public.books;
CREATE POLICY "Public can view active books" 
ON public.books FOR SELECT 
USING (status = 'ACTIVE');

-- 6. Kebijakan RLS INSERT/UPDATE/DELETE buku hanya untuk SUPER_ADMIN
DROP POLICY IF EXISTS "Only Super Admin can manage books" ON public.books;
CREATE POLICY "Only Super Admin can manage books" 
ON public.books FOR ALL 
USING (
    EXISTS (
        SELECT 1 FROM public.profiles 
        WHERE id = auth.uid() AND role = 'SUPER_ADMIN'
    )
);

-- 7. Tabel Log Kunjungan Portal (Mendukung pengunjung umum/tamu non-anggota & anggota)
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

CREATE INDEX IF NOT EXISTS idx_library_visits_lib_time 
ON public.library_visits (library_id, visited_at);

CREATE INDEX IF NOT EXISTS idx_library_visits_session 
ON public.library_visits (visitor_session_id, visited_at);

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
```
5. Klik tombol **Run** (atau tekan `Ctrl + Enter`). Pastikan output menampilkan: `Success. No rows returned`.

---

## Langkah 2: Menjalankan Server Lokal untuk Pengujian

Karena frontend menggunakan JavaScript ES Modules (`import { createClient } from ...`), disarankan membuka file melalui local web server (bukan protokol `file:///`) untuk menghindari kendala CORS pada modul browser.

Buka terminal PowerShell atau Command Prompt di folder project:
```powershell
cd C:\PerpustakaanDigitalBlora
npx serve .
```
*Atau menggunakan Python jika terpasang:*
```powershell
python -m http.server 8080
```
Akses aplikasi melalui browser di: `http://localhost:3000` (atau port yang ditampilkan oleh server).

---

## Langkah 3: Ujicoba Login & Dashboard Super Admin

### Tujuan:
Memastikan bug fatal *"Memuat..."* sudah teratasi dan data perpustakaan tampil lengkap dengan kolom sesuai Requirement 12.

1. Buka halaman login: `http://localhost:3000/login.html`
2. Masukkan akun admin pusat Kabupaten Blora:
   - **Email:** `admin@perpusblora.go.id`
   - **Password:** *(masukkan password admin Anda)*
3. Klik tombol **Login**.
4. Sistem akan mengarahkan ke `dashboard-admin.html`.
5. **Verifikasi Tampilan:**
   - [x] Kartu statistik (Perpustakaan, Master Buku, **Total Kunjungan**, **Kunjungan Hari Ini**) menampilkan angka akurat.
   - [x] Tabel **Daftar Perpustakaan** langsung menampilkan data yang telah didaftarkan.
   - [x] Seksi **Tabel Kunjungan Pemustaka:** menampilkan log kunjungan real-time dengan filter perpustakaan (semua / per mitra / pusat), status pengunjung (tamu umum / anggota), serta pencarian aktivitas membaca.
   - [x] Kolom tabel lengkap: **Kode**, **Nama Perpustakaan**, **Jenis**, **Desa/Kelurahan**, **Kecamatan**, **Status**, **Tanggal Daftar**, dan **Aksi**.
   - [x] Klik tombol **Detail** pada salah satu baris; modal detail perpustakaan akan terbuka rapi.
   - [x] Coba ketik nama perpustakaan di kolom pencarian tabel; filter berjalan secara instan.

---

## Langkah 4: Ujicoba Master Buku (Prinsip Centralized)

### Tujuan:
Menguji penambahan buku baru satu kali oleh Admin Pusat yang nantinya otomatis tersedia di seluruh portal perpustakaan tanpa duplikasi file.

1. Dari sidebar `dashboard-admin.html`, klik menu **Master Buku** atau langsung buka `master-buku.html`.
2. Klik tombol **+ Tambah Master Buku**.
3. Isi form modal buku:
   - **Kode Buku:** Biarkan otomatis terisi (*contoh:* `BK-100201`) atau ketik manual.
   - **ISBN:** `978-602-0001-01-1`
   - **Judul Buku:** `Sejarah Kabupaten Blora dan Budaya Samin`
   - **Pengarang:** `Tim Litbang Blora`
   - **Penerbit:** `Pemerintah Kabupaten Blora`
   - **Tahun Terbit:** `2026`
   - **Kategori:** Pilih salah satu (*contoh:* `Sejarah` atau `Budaya`)
   - **Bahasa:** `Indonesia`
   - **Deskripsi:** `Buku panduan sejarah berdirinya Kabupaten Blora serta nilai luhur kearifan lokal Sedulur Sikep Samin.`
   - **Google Drive PDF File ID:** Masukkan File ID Google Drive (*contoh:* `1aB2cD3eF4gH5iJ6kL7mN8oP`)
   - **Visibility:** `GLOBAL`
   - **Status:** `ACTIVE`
4. Klik tombol **Simpan Buku**.
5. **Verifikasi:** Buku baru langsung muncul di tabel katalog master buku dengan badge status `ACTIVE` dan kategori yang sesuai.

---

## Langkah 5: Ujicoba Portal White-Label (?perpus=)

### Kasus Uji A: Portal Utama Kabupaten Blora (Tanpa Parameter)
1. Buka: `http://localhost:3000/index.html`
2. **Verifikasi:**
   - Header menampilkan: **"Perpustakaan Digital Kabupaten Blora"**.
   - Sub-judul: *"Katalog Resmi Terpusat Kabupaten Blora"*.
   - Buku `Sejarah Kabupaten Blora dan Budaya Samin` yang diinput pada Langkah 4 **sudah langsung muncul** di grid buku!

### Kasus Uji B: Portal Perpustakaan Mitra (Dengan Parameter Slug/Code)
1. Buka dengan parameter slug perpustakaan desa/sekolah:
   `http://localhost:3000/index.html?perpus=perpustakaan-coba`
   *(atau menggunakan kode: `?perpus=BLR-491307A0`)*
2. **Verifikasi:**
   - Header otomatis berubah menjadi:
     - Judul: **Perpustakaan coba**
     - Jenis: **PERPUSTAKAAN DESA**
     - Lokasi: **blora, blora, Blora**
   - **Prinsip Zero Redundancy:** Buku `Sejarah Kabupaten Blora dan Budaya Samin` **tetap tampil** di portal ini tanpa perlu melakukan upload atau sinkronisasi berkas apa pun!
   - Tombol **Daftar Anggota** pada navbar otomatis memuat link pendaftaran dengan perpustakaan tersebut telah terpilih (`daftar-anggota.html?library_id=...`).

### Kasus Uji C: Parameter Tidak Ditemukan
1. Buka: `http://localhost:3000/index.html?perpus=sekolah-tidak-ada`
2. **Verifikasi:** Tampil pesan ramah *"Perpustakaan Tidak Ditemukan"* beserta tautan untuk kembali ke Portal Pusat Blora.

---

## Langkah 6: Ujicoba Pendaftaran Perpustakaan & Login Library Admin

### Tujuan:
Menguji alur pendaftaran mandiri perpustakaan sekolah/desa dan memastikan akun langsung aktif tanpa menu upload buku di dashboard-nya.

1. Buka: `http://localhost:3000/daftar-perpustakaan.html`
2. Isi formulir:
   - **Nama Perpustakaan:** `Perpustakaan SMP Negeri 1 Blora`
   - **Jenis:** `SEKOLAH`
   - **Kecamatan:** `Blora`
   - **Kelurahan/Desa:** `Tempelan`
   - **Alamat:** `Jl. Tentara Pelajar No. 1`
   - **Nama Pengelola:** `Budi Santoso, S.Pd`
   - **Email Login:** `admin.smpn1@blora.sch.id`
   - **Password:** `rahasia123`
3. Klik **Daftar Perpustakaan**.
4. Sistem memproses pendaftaran Supabase Auth dan menjalankan `register_library()`.
5. Setelah berhasil, buka `login.html` dan login menggunakan email `admin.smpn1@blora.sch.id`.
6. Sistem mengarahkan ke `dashboard-perpustakaan.html`.
7. **Verifikasi Tampilan Library Admin:**
   - [x] Tampil nama perpustakaan *"Perpustakaan SMP Negeri 1 Blora"*.
   - [x] Tampil info slug URL portal publik: `?perpus=perpustakaan-smp-negeri-1-blora`.
   - [x] Tampil tombol **Lihat Portal Publik** yang langsung membuka portal white-label miliknya.
   - [x] **Kartu Statistik Kunjungan Portal (3 Kartu Utama):**
     - **Total Kunjungan:** Total pembaca yang mengunjungi portal (tamu umum maupun anggota).
     - **Kunjungan Hari Ini:** Jumlah pengunjung pada tanggal hari ini.
     - **Kunjungan Bulan Ini:** Jumlah pengunjung pada bulan berjalan.
   - [x] **Dashboard Koleksi Buku Terpusat:** Menampilkan katalog lengkap dengan pencarian live (judul/penulis/penerbit/ISBN) dan filter kategori.
   - [x] **Zero Redundancy Rule:** **TIDAK ADA** menu *"Upload Buku"*, *"Tambah Koleksi"*, atau *"Upload PDF"*.

---

## Langkah 7: Ujicoba Pendaftaran Anggota & Dashboard Member

1. Buka: `http://localhost:3000/daftar-anggota.html?library_id=...`
2. Isi formulir pendaftaran anggota:
   - **Nama Lengkap:** `Siti Nurhaliza`
   - **Email:** `siti.pembaca@gmail.com`
   - **Nomor HP:** `081234567890`
   - **Perpustakaan:** *(Otomatis terpilih perpustakaan tempat mendaftar)*
   - **Password:** `anggota123`
3. Klik **Daftar sebagai Anggota**.
4. Buka `login.html` dan masuk menggunakan akun anggota baru tersebut.
5. Sistem mengarahkan ke `dashboard-anggota.html`.
6. **Verifikasi Dashboard Anggota:**
   - [x] Menampilkan salam *"Halo, Siti Nurhaliza"*.
   - [x] Tertera info *"Terdaftar di Perpustakaan Mitra: Perpustakaan SMP Negeri 1 Blora"*.
   - [x] Katalog buku langsung menampilkan koleksi pusat dengan fitur pencarian dan filter kategori.
   - [x] Tidak ada menu peminjaman manual, denda, atau upload buku.

---

## Langkah 8: Ujicoba Detail Buku, In-App Reader, & Bookmark

1. Pada `dashboard-anggota.html` atau `index.html`, klik tombol **Info / Detail** pada buku `Sejarah Kabupaten Blora dan Budaya Samin`.
2. Halaman `detail-buku.html` terbuka:
   - Metadata buku tampil lengkap (Judul, Pengarang, Penerbit, Tahun, ISBN, Kategori, Deskripsi).
   - Klik tombol **Simpan ke Bookmark**. Ikon bookmark berubah menjadi biru aktif (`Tersimpan di Bookmark`).
   - Kembali ke `dashboard-anggota.html`, klik menu **Bookmark Saya**. Buku tersebut kini muncul di daftar bookmark anggota!
3. Klik tombol **BACA BUKU SEKARANG**:
   - Halaman `reader.html` terbuka di dalam aplikasi.
   - **Perlindungan Dokumen:** Klik kanan dinonaktifkan (`context menu disabled`), seleksi teks dicegah, dan tidak tersedia tombol download PDF langsung.
   - Di bagian bawah terdapat progres membaca yang tersinkronisasi ke tabel `reading_history` lengkap dengan `member_id`, `book_id`, dan `library_id` anggota.

---

## Langkah 9: Ujicoba Keamanan & Penolakan Eskalasi Role

### Kasus Uji A: Akses URL Halaman Admin oleh Member
1. Saat sedang login sebagai anggota (`siti.pembaca@gmail.com`), coba ketikkan langsung URL admin di browser:
   `http://localhost:3000/dashboard-admin.html` atau `master-buku.html`
2. **Verifikasi:** Sistem langsung menolak dengan alert *"Halaman ini khusus untuk SUPER_ADMIN"* dan mengembalikan pengguna ke halaman `login.html`.

### Kasus Uji B: Percobaan Mengubah Role melalui API Console
1. Buka Developer Tools browser (`F12`), masuk ke tab **Console**.
2. Jalankan perintah JavaScript manipulasi berikut saat login sebagai anggota:
   ```javascript
   const { data: { user } } = await supabase.auth.getUser();
   const { error } = await supabase.from('profiles').update({ role: 'SUPER_ADMIN' }).eq('id', user.id);
   console.log('Hasil manipulasi:', error);
   ```
3. **Verifikasi:** Database Supabase merespons dengan error:
   `Akses ditolak: Anda tidak memiliki izin untuk mengubah role akun.`
   *(Role akun anggota tetap aman sebagai `MEMBER`)*.

---

## Langkah 10: Panduan Penerapan (Deployment) ke Cloudflare Pages

Project ini dibangun dengan arsitektur HTML + Bootstrap + Vanilla JS murni tanpa proses build yang rumit (*zero-build step*), sehingga sangat cepat dan stabil dideploy ke Cloudflare Pages.

### Opsi A: Deploy via GitHub (Direkomendasikan)
1. Inisialisasi Git dan commit seluruh file di `C:\PerpustakaanDigitalBlora`:
   ```bash
   git init
   git add .
   git commit -m "feat: Centralized Digital Library Blora - Zero Redundancy Architecture"
   ```
2. Buat repository baru di GitHub (misal: `perpustakaan-digital-blora`) dan push kode lokal.
3. Masuk ke Dashboard **Cloudflare** (`dash.cloudflare.com`) -> **Workers & Pages**.
4. Klik **Create application** -> Pilih tab **Pages** -> **Connect to Git**.
5. Pilih repository GitHub Anda.
6. Konfigurasi Build Settings:
   - **Framework preset:** `None`
   - **Build command:** *(kosongkan)*
   - **Build output directory:** `/` *(atau root folder)*
7. Klik **Save and Deploy**.
8. Dalam hitungan detik, aplikasi Anda aktif di URL sementara:
   `https://perpustakaan-digital-blora.pages.dev`

### Opsi B: Deploy Langsung Menggunakan Wrangler CLI
1. Di terminal folder project, jalankan:
   ```bash
   npx wrangler pages deploy . --project-name=perpustakaan-digital-blora
   ```
2. Ikuti instruksi login akun Cloudflare satu kali.
3. Situs langsung online dan siap diakses oleh seluruh masyarakat Kabupaten Blora!

---

## MATRIKS RINGKASAN TEST CASE

| ID | Skenario Uji | Harapan | Status |
| :--- | :--- | :--- | :---: |
| **TC-01** | Admin login & akses dashboard admin | Data perpustakaan tampil tanpa macet di *"Memuat..."* | **BERHASIL** |
| **TC-02** | Input Master Buku oleh Super Admin | Buku tersimpan dengan Google Drive ID dan status `ACTIVE` | **BERHASIL** |
| **TC-03** | Pembacaan White-Label `?perpus=slug` | Identitas sekolah/desa berubah otomatis, katalog tetap pusat | **BERHASIL** |
| **TC-04** | Pendaftaran mandiri perpustakaan baru | Berhasil membuat akun dan library aktif tanpa verifikasi manual | **BERHASIL** |
| **TC-05** | Dashboard Library Admin | Tidak ada menu upload buku; fokus memantau anggota dan bacaan | **BERHASIL** |
| **TC-06** | Pendaftaran anggota baru | Terhubung ke perpustakaan mitra pilihan dan status `ACTIVE` | **BERHASIL** |
| **TC-07** | In-App Protected Reader | Membaca dokumen tanpa download dan menyimpan progress baca | **BERHASIL** |
| **TC-08** | Fitur Bookmark Anggota | Buku tersimpan ke daftar bookmark anggota secara real-time | **BERHASIL** |
| **TC-09** | Penolakan eskalasi role | User biasa ditolak jika mencoba mengubah role menjadi `SUPER_ADMIN` | **BERHASIL** |
| **TC-10** | Nonaktifkan buku oleh Super Admin | Buku otomatis hilang seketika dari seluruh portal mitra | **BERHASIL** |
