#!/usr/bin/env bash
# appdesk.sh - Kelola shortcut aplikasi (.desktop) + perintah terminal di Linux
# Penggunaan: bash appdesk.sh
#
# Fitur:
#   Add    : buat shortcut menu/Desktop + perintah terminal (mis. ketik: opera)
#   Edit   : ubah nama, ikon, lokasi file, argumen, kategori, perintah terminal, dll
#   Delete : hapus shortcut, perintah terminal, salinan Desktop, ikon, dan bersihkan cache
#   List   : tampilkan semua yang pernah ditambahkan lewat skrip ini
#
# Perintah terminal bisa dipakai bersama proxychains, contoh:
#   proxychains4 opera

set -u

# ---------- Warna ----------
G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; B="\033[1;34m"; N="\033[0m"
info() { echo -e "${B}[i]${N} $*"; }
ok()   { echo -e "${G}[✓]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[x]${N} $*" >&2; }

APP_DIR="$HOME/.local/share/applications"
BIN_DIR="$HOME/.local/bin"
ICON_DIR="$HOME/.local/share/icons/appdesk"

# Data satu entri (dipakai Add & Edit)
E_FILE=""; E_NAME=""; E_SLUG=""; E_EXEC=""; E_ARGS=""; E_ICON=""
E_COMMENT=""; E_CATS=""; E_TERM="false"; E_URL="y"; E_CMD=""; E_DC="n"
OLD_LAUNCHER=""; OLD_DCOPY=""

# ---------- Helper ----------
expand_path() { local p="$1"; echo "${p/#\~/$HOME}"; }

ask_yn() {
    local q="$1" def="${2:-n}" hint ans
    [[ "$def" == "y" ]] && hint="Y/n" || hint="y/N"
    read -r -p "$q [$hint]: " ans
    ans="${ans:-$def}"
    [[ "${ans,,}" == "y" || "${ans,,}" == "ya" ]]
}

get_key() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-; }

desktop_dir() { xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop"; }

refresh_db() {
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$APP_DIR" 2>/dev/null
}

ensure_path() {
    mkdir -p "$BIN_DIR"
    case ":$PATH:" in *":$BIN_DIR:"*) return 0 ;; esac
    warn "$BIN_DIR belum ada di PATH."
    local line='export PATH="$HOME/.local/bin:$PATH"' rc added=0
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$rc" ]] && ! grep -qF '.local/bin' "$rc"; then
            printf '\n# Ditambahkan oleh appdesk.sh\n%s\n' "$line" >> "$rc"
            ok "PATH ditambahkan ke $rc"; added=1
        fi
    done
    export PATH="$BIN_DIR:$PATH"
    (( added )) && info "Buka terminal baru atau jalankan: source ~/.zshrc (atau ~/.bashrc)"
}

make_slug() { echo "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9._-'; }

# Prompt dengan isian awal (bisa diedit). Hasil di variabel REPLY_V
prompt_edit() {
    local label="$1" cur="$2"
    if [[ -t 0 ]]; then
        read -r -e -i "$cur" -p "$label: " REPLY_V
    else
        read -r -p "$label [$cur]: " REPLY_V
    fi
}

# ---------- Daftar entri ----------
list_entries() {
    ENTRIES=()
    local f
    for f in "$APP_DIR"/*.desktop; do
        [[ -f "$f" ]] || continue
        grep -q '^X-AppDesk=true' "$f" && ENTRIES+=("$f")
    done
}

show_entries() {
    list_entries
    if (( ${#ENTRIES[@]} == 0 )); then
        warn "Belum ada shortcut yang ditambahkan lewat skrip ini."
        return 1
    fi
    local i f cmd
    for i in "${!ENTRIES[@]}"; do
        f="${ENTRIES[$i]}"
        cmd="$(get_key "$f" X-AppDesk-Cmd)"
        printf "  %d) %s  (perintah: %s)\n" "$((i+1))" "$(get_key "$f" Name)" "${cmd:--}"
    done
    return 0
}

pick_entry() {
    show_entries || return 1
    local NUM
    read -r -p "Pilih nomor (Enter untuk batal): " NUM
    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || (( NUM < 1 || NUM > ${#ENTRIES[@]} )); then
        info "Dibatalkan."; return 1
    fi
    E_FILE="${ENTRIES[$((NUM-1))]}"
    return 0
}

# Muat entri dari file .desktop ke variabel E_*
load_entry() {
    local f="$1" ex rest
    E_FILE="$f"
    E_NAME="$(get_key "$f" Name)"
    E_COMMENT="$(get_key "$f" Comment)"
    E_ICON="$(get_key "$f" Icon)"
    E_CATS="$(get_key "$f" Categories)"
    E_TERM="$(get_key "$f" Terminal)"; E_TERM="${E_TERM:-false}"
    E_SLUG="$(get_key "$f" X-AppDesk-Slug)"; E_SLUG="${E_SLUG:-$(basename "$f" .desktop)}"
    E_CMD="$(get_key "$f" X-AppDesk-Cmd)"
    OLD_LAUNCHER="$(get_key "$f" X-AppDesk-Launcher)"
    OLD_DCOPY="$(get_key "$f" X-AppDesk-DesktopCopy)"
    [[ -n "$OLD_DCOPY" ]] && E_DC="y" || E_DC="n"

    E_EXEC="$(get_key "$f" X-AppDesk-Exec)"
    if [[ -n "$E_EXEC" ]]; then
        E_ARGS="$(get_key "$f" X-AppDesk-Args)"
        E_URL="$(get_key "$f" X-AppDesk-Url)"; E_URL="${E_URL:-y}"
    else
        # Fallback: baca dari baris Exec
        ex="$(get_key "$f" Exec)"
        [[ "$ex" == *" %U" ]] && E_URL="y" || E_URL="n"
        ex="${ex% %U}"
        if [[ "$ex" == \"* ]]; then
            rest="${ex#\"}"; E_EXEC="${rest%%\"*}"; E_ARGS="${rest#*\"}"
            E_ARGS="${E_ARGS# }"
        else
            E_EXEC="${ex%% *}"; E_ARGS=""
        fi
    fi
}

# ---------- Input dengan validasi ----------
ask_exec() {
    local def="${1:-}" v
    while true; do
        if [[ -n "$def" ]]; then
            prompt_edit "Lokasi file executable" "$def"; v="${REPLY_V}"
        else
            read -r -e -p "Lokasi file executable (contoh: ~/Downloads/opera/opera): " v
        fi
        v="$(expand_path "$v")"
        if [[ -f "$v" ]]; then E_EXEC="$v"; break; fi
        err "File tidak ditemukan: $v"
        if ask_yn "Coba cari otomatis dengan nama '${E_NAME,,}'?" y; then
            info "Mencari di home (bisa beberapa detik)..."
            local FOUND=() NUM i
            mapfile -t FOUND < <(find "$HOME" -type f -iname "${E_NAME,,}" -perm -u+x 2>/dev/null | head -n 10)
            if (( ${#FOUND[@]} == 0 )); then
                warn "Tidak ada hasil."
            else
                for i in "${!FOUND[@]}"; do echo "  $((i+1))) ${FOUND[$i]}"; done
                read -r -p "Pilih nomor (Enter untuk batal): " NUM
                if [[ "$NUM" =~ ^[0-9]+$ ]] && (( NUM >= 1 && NUM <= ${#FOUND[@]} )); then
                    E_EXEC="${FOUND[$((NUM-1))]}"; break
                fi
            fi
        fi
    done
    if [[ ! -x "$E_EXEC" ]]; then
        warn "File belum executable."
        ask_yn "Jalankan chmod +x pada file ini?" y && chmod +x "$E_EXEC" && ok "Izin eksekusi diberikan."
    fi
}

# Atur ikon. $1 = default. Return 1 jika gagal (E_ICON tidak berubah)
set_icon() {
    local def="${1:-}" v old="$E_ICON" dest
    read -r -e -p "Lokasi ikon (path file .png/.svg atau nama ikon sistem)${def:+ [$def]}: " v
    v="${v:-$def}"; v="$(expand_path "$v")"
    if [[ -z "$v" ]]; then E_ICON="application-x-executable"; return 0; fi
    if [[ "$v" == */* ]]; then
        if [[ ! -f "$v" ]]; then err "File ikon tidak ditemukan: $v"; return 1; fi
        if [[ "$v" != "$ICON_DIR/"* ]] && \
           ask_yn "Salin ikon ke $ICON_DIR (aman jika file asli dipindah/dihapus)?" y; then
            mkdir -p "$ICON_DIR"
            dest="$ICON_DIR/${E_SLUG}.${v##*.}"
            cp -f "$v" "$dest" && v="$dest"
        fi
    fi
    E_ICON="$v"
    if [[ "$old" == "$ICON_DIR/"* && "$old" != "$E_ICON" ]]; then rm -f -- "$old"; fi
    return 0
}

ask_cmd() {
    local def="${1:-}" v existing
    while true; do
        prompt_edit "Nama perintah terminal (kosongkan = tanpa perintah)" "$def"; v="${REPLY_V}"
        if [[ -z "$v" ]]; then E_CMD=""; return; fi
        if ! [[ "$v" =~ ^[A-Za-z0-9._-]+$ ]]; then
            err "Gunakan huruf, angka, titik, minus, underscore (tanpa spasi)."; continue
        fi
        existing="$(command -v "$v" 2>/dev/null || true)"
        if [[ -n "$existing" && "$existing" != "$BIN_DIR/$v" ]]; then
            warn "Perintah '$v' sudah ada di sistem: $existing"
            warn "Versi Anda dipakai lebih dulu hanya jika $BIN_DIR ada di depan PATH."
        fi
        if [[ -e "$BIN_DIR/$v" && "$BIN_DIR/$v" != "$OLD_LAUNCHER" ]]; then
            ask_yn "$BIN_DIR/$v sudah ada. Timpa?" n || continue
        fi
        E_CMD="$v"; ensure_path; return
    done
}

# ---------- Tulis semua file dari variabel E_* ----------
write_entry() {
    mkdir -p "$APP_DIR"
    local launcher="" dcopy="" exec_line

    # Perintah terminal
    if [[ -n "$E_CMD" ]]; then
        mkdir -p "$BIN_DIR"
        launcher="$BIN_DIR/$E_CMD"
        cat > "$launcher" <<EOF
#!/usr/bin/env bash
# Dibuat oleh appdesk.sh untuk: $E_NAME
exec "$E_EXEC" $E_ARGS "\$@"
EOF
        chmod +x "$launcher"
    fi
    if [[ -n "$OLD_LAUNCHER" && "$OLD_LAUNCHER" != "$launcher" && "$OLD_LAUNCHER" == "$BIN_DIR/"* ]]; then
        rm -f -- "$OLD_LAUNCHER"
    fi

    # Salinan Desktop
    if [[ "$E_DC" == "y" ]]; then
        mkdir -p "$(desktop_dir)"
        dcopy="$(desktop_dir)/${E_SLUG}.desktop"
    fi
    if [[ -n "$OLD_DCOPY" && "$OLD_DCOPY" != "$dcopy" ]]; then rm -f -- "$OLD_DCOPY"; fi

    # Baris Exec
    exec_line="\"$E_EXEC\""
    [[ -n "$E_ARGS" ]] && exec_line="$exec_line $E_ARGS"
    [[ "$E_URL" == "y" ]] && exec_line="$exec_line %U"

    cat > "$E_FILE" <<EOF
[Desktop Entry]
Version=1.0
Name=$E_NAME
Comment=$E_COMMENT
Exec=$exec_line
Icon=$E_ICON
Terminal=$E_TERM
Type=Application
Categories=$E_CATS
StartupNotify=true
X-AppDesk=true
X-AppDesk-Slug=$E_SLUG
X-AppDesk-Cmd=$E_CMD
X-AppDesk-Launcher=$launcher
X-AppDesk-DesktopCopy=$dcopy
X-AppDesk-Exec=$E_EXEC
X-AppDesk-Args=$E_ARGS
X-AppDesk-Url=$E_URL
EOF
    chmod +x "$E_FILE"

    if [[ -n "$dcopy" ]]; then
        cp -f "$E_FILE" "$dcopy"
        chmod +x "$dcopy"
        command -v gio >/dev/null 2>&1 && gio set "$dcopy" metadata::trusted true 2>/dev/null
    fi

    OLD_LAUNCHER="$launcher"; OLD_DCOPY="$dcopy"
    refresh_db
}

# =====================================================================
#  ADD
# =====================================================================
add_app() {
    echo
    echo "------ TAMBAH SHORTCUT ------"
    E_ARGS=""; E_ICON=""; E_CMD=""; E_DC="n"; E_URL="y"; E_TERM="false"
    OLD_LAUNCHER=""; OLD_DCOPY=""

    while true; do
        read -r -p "Nama aplikasi (contoh: Opera): " E_NAME
        [[ -n "$E_NAME" ]] && break
        err "Nama tidak boleh kosong."
    done
    E_SLUG="$(make_slug "$E_NAME")"
    E_FILE="$APP_DIR/${E_SLUG}.desktop"

    if [[ -f "$E_FILE" ]] && ! ask_yn "Shortcut $E_FILE sudah ada. Timpa?" n; then
        err "Dibatalkan."; return
    fi

    ask_exec ""

    # Ikon: tawarkan gambar di folder aplikasi
    local DEFAULT_ICON="" cand
    for cand in "$(dirname "$E_EXEC")"/*.png "$(dirname "$E_EXEC")"/*.svg "$(dirname "$E_EXEC")"/*.xpm; do
        [[ -f "$cand" ]] && { DEFAULT_ICON="$cand"; break; }
    done
    until set_icon "$DEFAULT_ICON"; do :; done

    read -r -p "Komentar/deskripsi [$E_NAME]: " E_COMMENT
    E_COMMENT="${E_COMMENT:-$E_NAME}"

    echo "Kategori umum: Network;WebBrowser;  Utility;  Development;  Graphics;  Office;  Game;"
    read -r -p "Kategori [Utility;]: " E_CATS
    E_CATS="${E_CATS:-Utility;}"
    [[ "$E_CATS" != *";" ]] && E_CATS="${E_CATS};"

    local MORE=""
    ask_yn "Tambahkan --no-sandbox? (perlu jika menjalankan sebagai root)" n && E_ARGS="--no-sandbox"
    read -r -p "Argumen tambahan lain (Enter untuk lewati): " MORE
    [[ -n "$MORE" ]] && E_ARGS="${E_ARGS:+$E_ARGS }$MORE"
    ask_yn "Jalankan di dalam terminal?" n && E_TERM="true"
    ask_yn "Aplikasi menerima URL/file (tambahkan %U)?" y && E_URL="y" || E_URL="n"

    if ask_yn "Buat perintah terminal (agar bisa diketik & dipakai dengan proxychains)?" y; then
        ask_cmd "$E_SLUG"
    fi
    ask_yn "Salin juga ke Desktop?" y && E_DC="y"

    write_entry
    echo
    ok "Shortcut dibuat: $E_FILE"
    [[ -n "$OLD_DCOPY" ]] && { ok "Salinan Desktop: $OLD_DCOPY"; info "Jika ikon bertanda peringatan, klik kanan lalu 'Allow Launching'."; }
    [[ -n "$OLD_LAUNCHER" ]] && ok "Perintah terminal: $OLD_LAUNCHER"
    info "Cari '$E_NAME' di menu aplikasi. Jika belum muncul, logout lalu login."
    if [[ -n "$E_CMD" ]]; then
        info "Jalankan dari terminal : $E_CMD"
        info "Dengan proxychains     : proxychains4 $E_CMD"
    fi
}

# =====================================================================
#  EDIT
# =====================================================================
edit_app() {
    echo
    echo "------ EDIT SHORTCUT ------"
    pick_entry || return
    load_entry "$E_FILE"

    local CH V changed="n"
    while true; do
        echo
        echo "Mengedit: $E_NAME"
        echo "  1) Nama tampilan     : $E_NAME"
        echo "  2) Ikon              : $E_ICON"
        echo "  3) Lokasi executable : $E_EXEC"
        echo "  4) Argumen           : ${E_ARGS:--}"
        echo "  5) Komentar          : $E_COMMENT"
        echo "  6) Kategori          : $E_CATS"
        echo "  7) Jalankan di terminal : $E_TERM"
        echo "  8) Terima URL/file (%U) : $E_URL"
        echo "  9) Perintah terminal : ${E_CMD:--}"
        echo " 10) Salinan Desktop   : $E_DC"
        echo "  S) Simpan & selesai     B) Batal (buang perubahan)"
        read -r -p "Pilih: " CH
        case "${CH,,}" in
            1) prompt_edit "Nama tampilan" "$E_NAME"
               [[ -n "$REPLY_V" ]] && { E_NAME="$REPLY_V"; changed="y"; } ;;
            2) if set_icon "$E_ICON"; then changed="y"; fi ;;
            3) local prev="$E_EXEC"; ask_exec "$E_EXEC"
               [[ "$E_EXEC" != "$prev" ]] && changed="y" ;;
            4) prompt_edit "Argumen (kosongkan untuk menghapus)" "$E_ARGS"
               E_ARGS="$REPLY_V"; changed="y" ;;
            5) prompt_edit "Komentar" "$E_COMMENT"
               E_COMMENT="${REPLY_V:-$E_NAME}"; changed="y" ;;
            6) prompt_edit "Kategori (pisahkan dengan ;)" "$E_CATS"
               V="${REPLY_V:-Utility;}"; [[ "$V" != *";" ]] && V="${V};"
               E_CATS="$V"; changed="y" ;;
            7) [[ "$E_TERM" == "true" ]] && E_TERM="false" || E_TERM="true"; changed="y" ;;
            8) [[ "$E_URL" == "y" ]] && E_URL="n" || E_URL="y"; changed="y" ;;
            9) ask_cmd "${E_CMD:-$E_SLUG}"; changed="y" ;;
           10) [[ "$E_DC" == "y" ]] && E_DC="n" || E_DC="y"; changed="y" ;;
            s) if [[ "$changed" == "n" ]]; then info "Tidak ada perubahan."; return; fi
               write_entry
               ok "Perubahan disimpan untuk '$E_NAME'."
               [[ -n "$E_CMD" ]] && info "Perintah terminal: $E_CMD  (proxychains4 $E_CMD)"
               return ;;
            b) if [[ "$changed" == "y" ]]; then
                   ask_yn "Buang semua perubahan?" n || continue
               fi
               info "Dibatalkan."; return ;;
            *) err "Pilihan tidak valid." ;;
        esac
    done
}

# =====================================================================
#  DELETE
# =====================================================================
delete_app() {
    echo
    echo "------ HAPUS SHORTCUT ------"
    pick_entry || return
    load_entry "$E_FILE"

    echo
    echo "Akan dihapus:"
    echo "  - $E_FILE"
    [[ -n "$OLD_DCOPY"    && -e "$OLD_DCOPY"    ]] && echo "  - $OLD_DCOPY"
    [[ -n "$OLD_LAUNCHER" && -e "$OLD_LAUNCHER" ]] && echo "  - $OLD_LAUNCHER"
    [[ "$E_ICON" == "$ICON_DIR/"* && -e "$E_ICON" ]] && echo "  - $E_ICON"
    ask_yn "Lanjutkan hapus '$E_NAME'?" n || { info "Dibatalkan."; return; }

    rm -f -- "$E_FILE"
    [[ -n "$OLD_DCOPY" ]] && rm -f -- "$OLD_DCOPY"
    [[ -n "$OLD_LAUNCHER" && "$OLD_LAUNCHER" == "$BIN_DIR/"* ]] && rm -f -- "$OLD_LAUNCHER"
    [[ "$E_ICON" == "$ICON_DIR/"* ]] && rm -f -- "$E_ICON"
    ok "Shortcut, perintah terminal, dan ikon salinan dihapus."

    # ---- Cache ----
    if ask_yn "Bersihkan cache '$E_NAME'?" y; then
        local n d CACHE_DIRS=() seen=" "
        for n in "$E_SLUG" "$E_CMD" "$E_NAME" "${E_NAME,,}"; do
            [[ -z "$n" ]] && continue
            d="$HOME/.cache/$n"
            if [[ -d "$d" && "$seen" != *" $d "* ]]; then CACHE_DIRS+=("$d"); seen+="$d "; fi
        done
        if (( ${#CACHE_DIRS[@]} == 0 )); then
            info "Tidak ada folder cache yang cocok di ~/.cache."
        else
            echo "Folder cache ditemukan:"
            for d in "${CACHE_DIRS[@]}"; do
                printf '  - %s (%s)\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
            done
            if ask_yn "Hapus folder cache di atas?" y; then
                for d in "${CACHE_DIRS[@]}"; do rm -rf -- "$d"; done
                ok "Cache dibersihkan."
            fi
        fi
    fi

    # ---- Konfigurasi (opsional, default TIDAK) ----
    local CONF_DIRS=() seen2=" " n2 d2
    for n2 in "$E_SLUG" "$E_CMD" "${E_NAME,,}"; do
        [[ -z "$n2" ]] && continue
        d2="$HOME/.config/$n2"
        if [[ -d "$d2" && "$seen2" != *" $d2 "* ]]; then CONF_DIRS+=("$d2"); seen2+="$d2 "; fi
    done
    if (( ${#CONF_DIRS[@]} > 0 )); then
        echo
        warn "Ditemukan data/konfigurasi (profil, bookmark, password tersimpan, dll):"
        for d2 in "${CONF_DIRS[@]}"; do echo "  - $d2"; done
        if ask_yn "Hapus juga? (TIDAK BISA dikembalikan)" n; then
            for d2 in "${CONF_DIRS[@]}"; do rm -rf -- "$d2"; done
            ok "Konfigurasi dihapus."
        else
            info "Konfigurasi dibiarkan."
        fi
    fi

    refresh_db
    echo
    ok "Selesai. File aplikasi aslinya (folder unduhan) tidak disentuh."
}

# =====================================================================
#  MENU UTAMA
# =====================================================================
main_menu() {
    local CH
    while true; do
        echo
        echo "=========================================="
        echo "   APPDESK - Kelola Shortcut Aplikasi"
        echo "=========================================="
        echo "  1) Add    - tambah shortcut"
        echo "  2) Edit   - ubah ikon, nama, argumen, dll"
        echo "  3) Delete - hapus shortcut + bersihkan cache"
        echo "  4) List   - lihat yang sudah ditambahkan"
        echo "  5) Keluar"
        read -r -p "Pilih [1-5]: " CH || exit 0
        case "${CH,,}" in
            1|add)    add_app ;;
            2|edit)   edit_app ;;
            3|delete) delete_app ;;
            4|list)   echo; show_entries ;;
            5|q|exit|keluar) echo "Sampai jumpa."; exit 0 ;;
            *) err "Pilihan tidak valid." ;;
        esac
    done
}

main_menu
