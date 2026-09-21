import os
from pathlib import Path
from django.core.exceptions import ImproperlyConfigured

BASE_DIR = Path(__file__).resolve().parent.parent
INSURANCE_ENV = os.getenv("INSURANCE_ENV", "demo").lower()
if INSURANCE_ENV not in {"demo", "production"}:
    raise ImproperlyConfigured("INSURANCE_ENV must be demo or production")
if INSURANCE_ENV == "production":
    raise ImproperlyConfigured(
        "insurance-backend is an isolated Mock/Demo service and is not approved for production"
    )

SECRET_KEY = os.getenv("DJANGO_SECRET_KEY", "unsafe-development-only-key")
DEBUG = os.getenv("DJANGO_DEBUG", "false").lower() == "true"
ALLOWED_HOSTS = [x.strip() for x in os.getenv("DJANGO_ALLOWED_HOSTS", "localhost,127.0.0.1").split(",") if x.strip()]
ENABLE_TEST_PAYMENTS = os.getenv("ENABLE_TEST_PAYMENTS", "true").lower() == "true"

INSTALLED_APPS = [
    "django.contrib.auth", "django.contrib.contenttypes", "django.contrib.sessions",
    "django.contrib.staticfiles", "rest_framework", "drf_spectacular", "insurance",
]
MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware", "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware", "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
]
ROOT_URLCONF = "config.urls"
TEMPLATES = [{"BACKEND": "django.template.backends.django.DjangoTemplates", "DIRS": [], "APP_DIRS": True, "OPTIONS": {"context_processors": []}}]
WSGI_APPLICATION = "config.wsgi.application"
DATABASES = {"default": {"ENGINE": "django.db.backends.sqlite3", "NAME": os.getenv("SQLITE_PATH", BASE_DIR / "db.sqlite3")}}
LANGUAGE_CODE = "ar"
TIME_ZONE = os.getenv("TZ", "Asia/Riyadh")
USE_I18N = True
USE_TZ = True
STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": ["rest_framework_simplejwt.authentication.JWTAuthentication"],
    "DEFAULT_PERMISSION_CLASSES": ["rest_framework.permissions.IsAuthenticated"],
    "DEFAULT_SCHEMA_CLASS": "drf_spectacular.openapi.AutoSchema",
    "EXCEPTION_HANDLER": "insurance.exceptions.api_exception_handler",
}
SPECTACULAR_SETTINGS = {
    "TITLE": "Mock Concord Insurance API", "VERSION": "1.0.0",
    "DESCRIPTION": "واجهة تجريبية لرحلة التأمين: Customer → Vehicle → Quote → Order → Payment → Policy",
    "SERVE_PERMISSIONS": ["rest_framework.permissions.AllowAny"],
}
PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "http://localhost:8000")
