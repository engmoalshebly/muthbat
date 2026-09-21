#!/bin/sh
set -e
python manage.py migrate --noinput
if [ "${INSURANCE_ENV:-demo}" = "demo" ]; then
  python manage.py create_test_user
fi
python manage.py collectstatic --noinput
exec gunicorn config.wsgi:application --bind 0.0.0.0:8000 --workers 2 --access-logfile -
