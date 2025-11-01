#!/usr/bin/env bash
# import-copy.sh -- Termux için: bir GitHub repo'sunun dosyalarını kopyala, hedef repo oluştur (MIT lisanslı) ve pushla.
# Gelişmiş sürüm: Argüman desteği, star'lama, private repo ve topic desteği içerir.
set -euo pipefail

# --- Varsayılanlar ---
SRC_INPUT=""
TARGET_REPO=""
TARGET_DESC=""
TOPICS=""
IS_PRIVATE="n" # 'y' olarak değişirse private olur
# ---

usage() {
  echo "Kullanım: $0 [SEÇENEKLER]"
  echo
  echo "Bir GitHub reposunun içeriğini kopyalayıp sizin için yeni bir repoya (MIT lisanslı) pushlar."
  echo
  echo "Seçenekler:"
  echo "  -s, --source <owner/repo>   Kaynak GitHub reposu (örn: someuser/somerepo)"
  echo "  -t, --target <repo-adı>     Oluşturulacak yeni reponun adı"
  echo "  -d, --description <metin>   Yeni repo için açıklama (opsiyonel)"
  echo "  -p, --private               Yeni repoyu 'private' (gizli) olarak oluşturur (varsayılan: public)"
  echo "  --topics <\"t1,t2,t3\">     Repoya eklenecek konular (virgülle ayrılmış, opsiyonel)"
  echo "  -h, --help                  Bu yardım mesajını göster"
  echo
  echo "Eğer seçenekler kullanılmazsa, script bilgileri interaktif olarak soracaktır."
  exit 0
}

# Argümanları ayrıştır
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -s|--source) SRC_INPUT="$2"; shift ;;
    -t|--target) TARGET_REPO="$2"; shift ;;
    -d|--description) TARGET_DESC="$2"; shift ;;
    -p|--private) IS_PRIVATE="y" ;;
    --topics) TOPICS="$2"; shift ;;
    -h|--help) usage ;;
    *) echo "Bilinmeyen argüman: $1"; exit 1 ;;
  esac
  shift
done

# Gereksinimler kontrolü
for cmd in git curl jq; do
  if ! command -v $cmd >/dev/null 2>&1; then
    echo "Eksik: $cmd. Termux'ta kurmak için: pkg install $cmd"
    exit 1
  fi
done

echo "=== GitHub Repo Import & Create (Gelişmiş Sürüm) ==="

# Token (görünmez)
echo -n "GitHub Personal Access Token (repo yetkisi ile) gir (ekranda gözükmeyecek): "
read -s GHTOKEN
echo
if [[ -z "$GHTOKEN" ]]; then
  echo "Token gerekli. Çıkılıyor."
  exit 1
fi

# Eksik bilgileri interaktif olarak sor
if [[ -z "$SRC_INPUT" ]]; then
  read -p "Kaynak repo (https://github.com/owner/repo veya owner/repo): " SRC_INPUT
fi
if [[ -z "$TARGET_REPO" ]]; then
  read -p "Hedef repoda olması istenen isim (ör: benim-yeni-repo): " TARGET_REPO
fi
if [[ -z "$TARGET_DESC" ]]; then
  read -p "Hedef repo için açıklama (opsiyonel): " TARGET_DESC
fi
if [[ "$IS_PRIVATE" != "y" ]]; then # Sadece -p ile ayarlanmadıysa sor
  read -p "Hedef repo private (gizli) olsun mu? (y/n) [n]: " IS_PRIVATE_INPUT
  IS_PRIVATE=${IS_PRIVATE_INPUT:-n}
fi
if [[ -z "$TOPICS" ]]; then
  read -p "Repo konuları (virgülle ayırın, opsiyonel): " TOPICS
fi

# Gerekli alanların kontrolü
if [[ -z "$SRC_INPUT" || -z "$TARGET_REPO" ]]; then
  echo "Kaynak repo ve Hedef repo ismi mutlaka gereklidir. Çıkılıyor."
  exit 1
fi

# normalize: owner/repo
if [[ "$SRC_INPUT" =~ github.com/ ]]; then
  SRC_REPO=$(echo "$SRC_INPUT" | sed -E 's#https?://(www\.)?github.com/##; s#\.git$##; s#/$##')
else
  SRC_REPO="$SRC_INPUT"
fi

# Hedef owner (token ile oturum açan kullanıcı)
echo "Hedef repo hesabı (otomatik çekiliyor from token)..."
API_USER=$(curl -sS -H "Authorization: token $GHTOKEN" https://api.github.com/user)
USERNAME=$(echo "$API_USER" | jq -r .login)
if [[ "$USERNAME" == "null" || -z "$USERNAME" ]]; then
  echo "Token ile kullanıcı alınamadı. Token'ı ve internet bağlantısını kontrol et."
  exit 1
fi
echo "Token ile giriş yapan kullanıcı: $USERNAME"

# vars
TMPDIR="$(mktemp -d /data/data/com.termux/files/home/tmp-import-XXXX)"
cleanup() {
  echo "Temizlik..."
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

# 1) Kaynak repo erişilebilir mi?
echo "Kaynak repo kontrol ediliyor: $SRC_REPO"
if ! curl -sSf -H "Authorization: token $GHTOKEN" "https://api.github.com/repos/$SRC_REPO" >/dev/null; then
  echo "Kaynak repo bulunamadı veya erişilemiyor: $SRC_REPO"
  echo "Token'ınızın bu repoya erişimi olduğundan veya reponun public olduğundan emin olun."
  exit 1
fi

# 2) Hedef repo oluştur
PRIV_BOOL="false"
if [[ "${IS_PRIVATE,,}" == "y" ]]; then
  PRIV_BOOL="true"
  echo "Hedef repo oluşturuluyor: $USERNAME/$TARGET_REPO (Gizli & MIT lisanslı)"
else
  echo "Hedef repo oluşturuluyor: $USERNAME/$TARGET_REPO (Public & MIT lisanslı)"
fi

CREATE_PAYLOAD=$(jq -n --arg name "$TARGET_REPO" --arg desc "$TARGET_DESC" --argjson priv $PRIV_BOOL \
  '{name:$name, description:$desc, private:$priv, auto_init:false, license_template:"mit"}')
CREATE_RESP=$(curl -sS -H "Authorization: token $GHTOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  -d "$CREATE_PAYLOAD" https://api.github.com/user/repos)

# Hata kontrolü
if ! echo "$CREATE_RESP" | jq -e '.id' >/dev/null 2>&1; then
  ERRMSG=$(echo "$CREATE_RESP" | jq -r '.message // "unknown error"')
  echo "Repo oluşturulurken hata: $ERRMSG"
  exit 1
fi
echo "Hedef repo başarıyla oluşturuldu."

# 3) YENİ: Konuları (Topics) ekle
if [[ -n "$TOPICS" ]]; then
  echo "Konular ekleniyor: $TOPICS"
  # Konuları jq dizisine çevir: "t1, t2" -> ["t1", "t2"]
  TOPICS_PAYLOAD=$(echo "$TOPICS" | jq -R 'split(",") | map(select(length > 0) | ltrimstr(" ") | rtrimstr(" "))' | jq -n '{names: inputs}')
  
  curl -sS -X PUT -H "Authorization: token $GHTOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    -d "$TOPICS_PAYLOAD" "https://api.github.com/repos/$USERNAME/$TARGET_REPO/topics" >/dev/null
  echo "Konular eklendi."
fi

# 4) YENİ: Star'lama işlemleri
read -p "Kaynak repoyu ($SRC_REPO) star'lamak ister misin? (y/n) [y]: " DO_STAR_SRC
if [[ "${DO_STAR_SRC:-y}" == "y" ]]; then
  echo "Kaynak repo star'lanıyor..."
  curl -sS -X PUT -H "Authorization: token $GHTOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Content-Length: 0" "https://api.github.com/user/starred/$SRC_REPO" >/dev/null
fi

read -p "Yeni repoyu ($USERNAME/$TARGET_REPO) star'lamak ister misin? (y/n) [y]: " DO_STAR_TGT
if [[ "${DO_STAR_TGT:-y}" == "y" ]]; then
  echo "Hedef repo star'lanıyor..."
  curl -sS -X PUT -H "Authorization: token $GHTOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Content-Length: 0" "https://api.github.com/user/starred/$USERNAME/$TARGET_REPO" >/dev/null
fi

# 5) Kaynağın shallow clone'u
echo "Kaynak repo klonlanıyor (snapshot)…"
cd "$TMPDIR"
git clone --depth 1 "https://$GHTOKEN@github.com/$SRC_REPO.git" src || { echo "Clone başarısız"; exit 1; }

# 6) Hedef repo'yu klonla (içinde LICENSE olacak)
echo "Hedef repo klonlanıyor (içindeki MIT lisans dahil)..."
git clone "https://$GHTOKEN@github.com/$USERNAME/$TARGET_REPO.git" tgt

# 7) Kaynaktaki dosyaları hedefe kopyala ( .git hariç )
echo "Dosyalar kopyalanıyor..."
shopt -s dotglob
cd src
# check if target has LICENSE
cd ../tgt
HAS_LICENSE=false
if [[ -f LICENSE ]] || [[ -f LICENSE.md ]] || [[ -f LICENSE.txt ]]; then
  HAS_LICENSE=true
fi
cd ../src

# copy files
for f in * .[^.]*; do
  if [[ "$f" == "." || "$f" == ".." || "$f" == ".git" ]]; then continue; fi
  if $HAS_LICENSE && [[ "${f,,}" =~ ^license ]]; then
    echo "Target repo zaten LICENSE içeriyor — kaynak LICENSE atlanıyor: $f"
    continue
  fi
  cp -r "$f" "$TMPDIR/tgt/" || { echo "Kopyalama hatası: $f"; exit 1; }
done
shopt -u dotglob

# 8) Commit & push
cd "$TMPDIR/tgt"
DEFAULT_BRANCH=$(git rev-parse --abbrev-ref HEAD || echo "main")
git add --all

if git diff --cached --quiet; then
  echo "Kopyalanacak yeni dosya bulunamadı — değişiklik yok."
else
  git commit -m "Import: dosyalar kopyalandı from $SRC_REPO"
  git push origin "$DEFAULT_BRANCH"
  echo "Dosyalar pushlandı -> https://github.com/$USERNAME/$TARGET_REPO"
fi

echo "İşlem tamamlandı. Hedef repo: https://github.com/$USERNAME/$TARGET_REPO"
