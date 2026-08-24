# دليل تشغيل ونشر OpenWA للإنتاج والربط بالخدمة (Production Deployment & Integration Guide)

يوفر هذا الدليل الخطوات والإرشادات الشاملة لتشغيل خدمة **OpenWA** كبوابة WhatsApp API مستقرة ومؤمنة في بيئات الإنتاج (Production Environments)، بالإضافة إلى خطوات الربط السريع واختبار الجاهزية.

---

## ⚡ 1. البدء السريع: تشغيل الخدمة واختبارها في دقيقة واحدة

### 1.1 تشغيل الحاوية عبر Docker
```bash
# تشغيل خدمة OpenWA API ولوحة التحكم المدمجة
docker compose up -d openwa-api
```

### 1.2 استخراج مفتاح المصادقة الأساسي (API Key)
عند الإقلاع الأول، يولد النظام مفتاح أدمن مشفر ويحفظه تلقائياً. يمكنك قراءته من السجلات:
```bash
docker compose logs openwa-api | grep "owa_k1_"
```
أو ستجده في مخرجات السجل بصيغة: `owa_k1_xxxxxxxxxxxxxxxxxxxxxxxxxxxx`

### 1.3 الروابط الأساسية للخدمة:
* 📊 **لوحة التحكم المدمجة (Dashboard UI):** `http://localhost:2785/`
* 📚 **وثائق Swagger التفاعلية:** `http://localhost:2785/api/docs`
* 🩺 **فحص الجاهزية (Readiness Probe):** `http://localhost:2785/api/health/ready`
* 🚀 **عنوان الـ API الأساسي (Base URL):** `http://localhost:2785/api`

---

## 🧪 2. دورة الربط السريع (Quick API Integration Workflow)

### الخطوة 1: التحقق من جاهزية الخدمة (Health Check)
```bash
curl -X GET "http://localhost:2785/api/health/ready"
```
**الاستجابة المتوقعة (HTTP 200 OK):**
```json
{
  "status": "ok",
  "timestamp": "2026-08-17T06:30:00.000Z",
  "uptime": 45,
  "memory": {
    "rssMb": 164,
    "heapUsedMb": 68,
    "heapTotalMb": 96
  },
  "details": {
    "mainDatabase": { "status": "up" },
    "dataDatabase": { "status": "up", "type": "sqlite" }
  }
}
```

---

### الخطوة 2: إنشاء جلسة واتساب جديدة (Create Session)
```bash
curl -X POST "http://localhost:2785/api/sessions" \
  -H "X-API-Key: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "sales-bot"
  }'
```

---

### الخطوة 3: بدء الجلسة واستخراج رمز الاستجابة السريعة (Start & Get QR Code)
1. **بدء الجلسة:**
   ```bash
   curl -X POST "http://localhost:2785/api/sessions/SESSION_ID/start" \
     -H "X-API-Key: YOUR_API_KEY"
   ```

2. **جلب رمز الـ QR لمسحه بهاتفك:**
   ```bash
   curl -X GET "http://localhost:2785/api/sessions/SESSION_ID/qr" \
     -H "X-API-Key: YOUR_API_KEY"
   ```
   *(يمكنك مسح الـ QR مباشرة وبسهولة فائقة من لوحة التحكم على `http://localhost:2785/sessions`)*.

---

### الخطوة 4: إرسال رسالة تجريبية (Send Text Message)
بمجرد تحول حالة الجلسة إلى `READY` (جاهزة):
```bash
curl -X POST "http://localhost:2785/api/messages/text" \
  -H "X-API-Key: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "sessionId": "SESSION_ID",
    "to": "966501234567@c.us",
    "text": "مرحباً بك! تم إرسال هذه الرسالة بنجاح عبر بوابة OpenWA 🚀"
  }'
```

---

## 📋 3. متطلبات العتاد والسيرفر للإنتاج (System Requirements)

| المورد | الحد الأدنى (1-3 جلسات) | الموصى به (5-15 جلسة) | بيئات الضغط العالي (15+ جلسة) |
| :--- | :--- | :--- | :--- |
| **CPU** | 2 Cores | 4 Cores | 8+ Cores |
| **RAM** | 2 GB | 8 GB | 16+ GB |
| **Swap** | 2 GB | 4 GB | 8 GB |
| **Storage** | 20 GB SSD | 50 GB NVMe SSD | 100+ GB NVMe SSD |
| **Node.js** | v20.x أو v22.x LTS | v22.x LTS | v22.x LTS |
| **OS** | Ubuntu 22.04/24.04, Debian 12, Alpine, Windows Server | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |

> [!IMPORTANT]
> يستهلك كل حساب واتساب نشط (Chromium Browser Instance) ما بين **150MB إلى 350MB** من الذاكرة العشوائية (RAM). احرص دائماً على توفير مساحة **Swap** كافية لمنع انهيار السيرفر بسبب OOM (Out Of Memory).

---

## 🚀 4. خيارات التشغيل في الإنتاج (Production Deployment Modes)

### النمط 1: الحاوية الشاملة المدمجة (Single All-in-One Container - موصى به)
تشغيل الـ API ولوحة التحكم وقاعدة البيانات المدمجة في حاوية واحدة عالية الكفاءة:
```bash
docker compose up -d openwa-api
```
* **المنفذ المستخدم:** `2785` (API + Dashboard + WebSocket Events).
* **إدارة السجلات:** تدوير تلقائي عبر `json-file` بحد أقصى `20MB`.
* **مساحة الذاكرة المشتركة:** `shm_size: 2gb` لمنع انهيار صفحات Chromium.

---

### النمط 2: التشغيل الكامل مع Traefik Proxy ولوحة التحكم المخصصة (Multi-Container)
```bash
docker compose --profile with-dashboard --profile with-proxy up -d
```
* **لوحة التحكم:** `http://localhost:2886`
* **الـ API:** `http://localhost:2785/api`

---

### النمط 3: التشغيل الكامل مع PostgreSQL و Redis و MinIO (Enterprise Full-Stack)
```bash
docker compose --profile full up -d
```

---

### النمط 4: التشغيل كخدمة مستقلة خارج Docker عبر PM2
```bash
# تثبيت الاعتماديات وبناء المشروع
npm ci --production=false
npm run build
npm run dashboard:build

# تشغيل الخدمة عبر PM2
pm2 start ecosystem.config.js --env production
pm2 save
pm2 startup
```

---

## 🔒 5. إعداد Reverse Proxy وتأمين SSL (Nginx)

```nginx
server {
    listen 80;
    server_name api.yourdomain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name api.yourdomain.com;

    ssl_certificate /etc/letsencrypt/live/api.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.yourdomain.com/privkey.pem;

    client_max_body_size 50M;
    proxy_read_timeout 300s;
    proxy_connect_timeout 75s;

    location / {
        proxy_pass http://127.0.0.1:2785;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /socket.io/ {
        proxy_pass http://127.0.0.1:2785;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

---

## 💾 6. استراتيجية النسخ الاحتياطي واستعادة البيانات (Backup & Recovery)

المجلدات الحرجة التي يجب تضمينها في خطة النسخ الاحتياطي:
1. **بيانات الجلسات وحسابات واتساب**: `./data/sessions/`
2. **قواعد البيانات المحلية**: `./data/*.sqlite`
3. **الملفات والوسائط**: `./data/media/`

### سكريبت النسخ الاحتياطي اليومي (Cron Job):
```bash
#!/bin/bash
BACKUP_DIR="/backups/openwa/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"
tar -czf "$BACKUP_DIR/sessions_backup.tar.gz" -C /opt/openwa/data sessions
tar -czf "$BACKUP_DIR/databases_backup.tar.gz" -C /opt/openwa/data *.sqlite
find /backups/openwa/* -mtime +14 -exec rm -rf {} +
```

---

## 🛡️ 7. نصائح استقرار جلسات واتساب ومنع الحظر (WhatsApp Parity & Best Practices)

1. **البروكسي لكل جلسة (Proxy per Session)**:
   - عند إدارة عدة أرقام على نفس السيرفر، حدد `proxyUrl` عند إنشاء الجلسة لتوزيع عناوين الـ IP.
2. **تجنب الإرسال المفرط الفجائي**:
   - أضف تأخيراً عشوائياً (من 2 إلى 5 ثوانٍ) بين الرسائل المرسلة لتفادي خوارزميات رصد السلوك الآلي.
3. **الاعتماد على Webhooks**:
   - استقبل الرسائل والأحداث عبر Webhooks الفورية بدلاً من إرسال طلبات فحص مستمرة (Polling).
