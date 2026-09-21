import os
from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand

class Command(BaseCommand):
    help = "Create or update the API test user from environment variables"
    def handle(self, *args, **kwargs):
        username = os.getenv("TEST_API_USERNAME")
        password = os.getenv("TEST_API_PASSWORD")
        if not username or not password:
            self.stdout.write("Demo credentials are not configured; skipping test user creation.")
            return
        user, _ = get_user_model().objects.get_or_create(username=username)
        user.set_password(password); user.save()
        self.stdout.write(self.style.SUCCESS(f"Test API user ready: {username}"))
