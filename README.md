# ZeroSSL Auto SSL + cPanel

Script CLI bash buat issue SSL certificate dari ZeroSSL dan langsung deploy otomatis ke cPanel — tanpa perlu upload file manual, paste private key, atau buka browser.

## Cara Kerja

1. Generate private key + CSR di lokal
2. Bikin cert order ke ZeroSSL API
3. Auto-upload file validasi ke cPanel via UAPI
4. Polling status sampai cert ke-issue
5. Download cert dan langsung install ke cPanel

## Kebutuhan

- `openssl`, `curl`, `jq` ter-install di mesin
- Akun ZeroSSL (free): https://app.zerossl.com
- cPanel dengan API token

## Setup

**ZeroSSL API Key**
Login ke ZeroSSL → Developer → Copy Access Key

**cPanel API Token**
cPanel → Security → Manage API Tokens → Create

## Penggunaan

```bash
./zerossl.sh
```

Script akan meminta input satu per satu:

```
Domain        : toko.com
ZeroSSL key   : ****
cPanel IP     : 130.94.11.20
cPanel user   : myuser
cPanel token  : ****
```

## Output

File tersimpan di `./certs/<domain>/`:

| File | Keterangan |
|---|---|
| `privkey.pem` | Private key |
| `certificate.crt` | Certificate |
| `ca_bundle.crt` | CA Bundle |
| `fullchain.pem` | Certificate + CA (untuk Nginx/Apache) |

## Catatan

- Free plan ZeroSSL: maksimal 3 certificate aktif, 1 domain per cert
- Certificate berlaku 90 hari, jalankan ulang script untuk renew
- Butuh port 80 terbuka di server agar file validasi bisa diakses ZeroSSL
