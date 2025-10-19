#!/usr/bin/env bash
# import-copy.sh -- Termux için: bir GitHub repo'sunun dosyalarını kopyala, hedef repo oluştur (MIT lisanslı) ve pushla.
set -euo pipefail

# Gereksinimler kontrolü
for cmd in git curl jq; do
  if ! command -v $cmd >/dev/null 2>&1; then
    echo "Eksik: $cmd. Termux'ta kurmak için: pkg install $cmd"
    exit 1
  fi
done

echo "=== GitHub Repo Import & Create (MIT lisanslı) ==="

# Token (görünmez)
echo -n "GitHub Personal Access Token (repo yetkisi ile) gir (ekranda gözükmeyecek): "
read -s GHTOKEN
echo
if [[ -z "$GHTOKEN" ]]; then
  echo "Token gerekli. Çıkılıyor."
  exit 1
fi

# Kaynak repo girişi (çeşitli formatları destekle)
read -p "Kaynak repo (https://github.com/owner/repo veya owner/repo): " SRC_INPUT
if [[ -z "$SRC_INPUT" ]]; then
  echo "Kaynak repo gerekli."
  exit 1
fi

# normalize: owner/repo
if [[ "$SRC_INPUT" =~ github.com/ ]]; then
  # strip protocol and .git
  SRC_REPO=$(echo "$SRC_INPUT" | sed -E 's#https?://(www\.)?github.com/##; s#\.git$##; s#/$##')
else
  SRC_REPO="$SRC_INPUT"
fi

# hedef repo adı
read -p "Hedef repoda olması istenen isim (ör: benim-yeni-repo): " TARGET_REPO
if [[ -z "$TARGET_REPO" ]]; then
  echo "Hedef repo ismi gerekli."
  exit 1
fi

# YENİ EKLENDİ: Hedef repo açıklaması
read -p "Hedef repo için açıklama (opsiyonel, boş bırakılabilir): " TARGET_DESC

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
# DÜZELTME: 403 Rate Limit hatasını önlemek için token ile kontrol et
if ! curl -sSf -H "Authorization: token $GHTOKEN" "https://api.github.com/repos/$SRC_REPO" >/dev/null; then
  echo "Kaynak repo bulunamadı veya erişilemiyor: $SRC_REPO"
  echo "Token'ınızın bu repoya erişimi olduğundan veya reponun public olduğundan emin olun."
  exit 1
fi

# 2) Hedef repo oluştur (MIT lisans ile)
echo "Hedef repo oluşturuluyor: $USERNAME/$TARGET_REPO  (MIT lisans eklenecek)"
# DÜZELTME: Açıklama (description) eklendi
CREATE_PAYLOAD=$(jq -n --arg name "$TARGET_REPO" --arg desc "$TARGET_DESC" --argjson priv false \
  '{name:$name, description:$desc, private:$priv, auto_init:false, license_template:"mit"}')
CREATE_RESP=$(curl -sS -H "Authorization: token $GHTOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  -d "$CREATE_PAYLOAD" https://api.github.com/user/repos)

# Hata kontrolü
if echo "$CREATE_RESP" | jq -e '.id' >/dev/null 2>&1; then
  echo "Hedef repo başarıyla oluşturuldu."
else
  # eğer kullanıcı değil org oluşturulacaksa deneyelim (org sahibi sensin diye varsaymayız; genelde user yeter)
  ERRMSG=$(echo "$CREATE_RESP" | jq -r '.message // "unknown error"')
  echo "Repo oluşturulurken hata: $ERRMSG"
  echo "Eğer hedef bir organization ise ve token uygun izinlere sahipse, scripti manuel olarak güncelle veya org için repo oluştur."
  exit 1
fi

# 3) Kaynakun shallow clone'u
echo "Kaynak repo klonlanıyor (snapshot)…"
cd "$TMPDIR"
# Token'ı burada kullanmak özel (private) repoları da klonlamayı sağlar
git clone --depth 1 "https://$GHTOKEN@github.com/$SRC_REPO.git" src || { echo "Clone başarısız"; exit 1; }

# 4) Hedef repo'yu klonla (içinde LICENSE olacak)
echo "Hedef repo klonlanıyor (içindeki MIT lisans dahil)..."
git clone "https://$GHTOKEN@github.com/$USERNAME/$TARGET_REPO.git" tgt

# 5) Kaynaktaki dosyaları hedefe kopyala ( .git hariç )
echo "Dosyalar kopyalanıyor..."
shopt -s dotglob
# remove readme or license only if you want to overwrite; we KEEP target LICENSE (do not overwrite)
# copy but skip .git and skip LICENSE if target has it
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
  # skip . and ..
  if [[ "$f" == "." || "$f" == ".." ]]; then continue; fi
  # skip .git
  if [[ "$f" == ".git" ]]; then continue; fi
  # skip LICENSE if target already has one
  if $HAS_LICENSE && [[ "${f,,}" =~ ^license ]]; then
    echo "Target repo zaten LICENSE içeriyor — kaynak LICENSE atlanıyor: $f"
    continue
  fi
  # copy
  cp -r "$f" "$TMPDIR/tgt/" || { echo "Kopyalama hatası: $f"; exit 1; }
done
shopt -u dotglob

# 6) Commit & push
cd "$TMPDIR/tgt"
# Detect default branch (after clone)
DEFAULT_BRANCH=$(git rev-parse --abbrev-ref HEAD || echo "main")
git add --all
# check if there is something to commit
if git diff --cached --quiet; then
  echo "Değişiklik yok — push atlanıyor."
else
  git commit -m "Import: dosyalar kopyalandı from $SRC_REPO"
  git push origin "$DEFAULT_BRANCH"
  echo "Dosyalar pushlandı -> https://github.com/$USERNAME/$TARGET_REPO"
fi

echo "İşlem tamamlandı. Hedef repo: https://github.com/$USERNAME/$TARGET_REPO"
