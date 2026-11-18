# المساهمة

شكرًا لاهتمامك بتحسين Kali Virtual Security Lab.

## قبل فتح طلب دمج

1. حافظ على ملفات الصور والأقراص والأسرار خارج المستودع، ولا تضف ISO أو QCOW2 حتى لو كانت صغيرة.
2. لا تغيّر الترخيص Apache-2.0 أو مسارات الملفات الحالية دون تحديث كل المراجع.
3. اجعل الإعدادات نصية بسيطة، ولا تستخدم `source` لقراءة ملف إعداد يحرره المستخدم.
4. أبقِ VNC وSSH مقيدين إلى loopback، ولا تفعّل bridge تلقائياً.
5. أضف اختباراً غير هدّام لكل تغيير، ولا تفترض توفر KVM أو وجود Kali مثبت.

## التحقق محلياً

```bash
bash -n kali.sh start-kali.sh scripts/*.sh scripts/lib/*.sh tests/*.sh installer/*.sh security/*.sh
shellcheck -x -P scripts kali.sh start-kali.sh scripts/*.sh scripts/lib/*.sh tests/*.sh installer/*.sh security/*.sh
bash tests/test-config.sh
bash tests/test-security.sh
bash tests/test-storage.sh
bash tests/test-startup.sh
python3 tests/test-repository.py
```

اختبار QEMU يستخدم قرصاً صغيراً مؤقتاً وTCG، ولا ينزّل ISO. لا تشغّل الاختبارات على قرص مستخدم. اشرح بوضوح أي اختبار لم يمكن تنفيذه.

## طلبات الدمج

اكتب وصفاً موجزاً للمشكلة والحل، وسرداً بالاختبارات الفعلية ونتائجها. لا ترفق أسراراً أو ملفات ثنائية كبيرة. حافظ على التوثيق العربي الأساسي وأضف مصطلحات إنجليزية عند الحاجة.
