import secrets
from django.conf import settings
from django.db import models

def public_id(prefix):
    return f"{prefix}-{secrets.randbelow(900000) + 100000}"

def customer_id(): return public_id("CUS")
def vehicle_id(): return public_id("VEH")
def quote_id(): return public_id("QUT")
def offer_id(): return public_id("OFF")
def order_id(): return public_id("ORD")
def invoice_id(): return public_id("INV")
def payment_id(): return public_id("PAY")
def policy_id(): return public_id("POL")

class Customer(models.Model):
    # Every demo record belongs to the authenticated API user. This is the
    # tenant boundary; nullable keeps the demo migration compatible with any
    # pre-existing local rows, which remain inaccessible until reassigned.
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="insurance_customers",
        null=True,
        blank=True,
    )
    customer_id = models.CharField(max_length=20, unique=True, default=customer_id)
    national_id = models.CharField(max_length=30, unique=True)
    birth_date = models.DateField()
    phone = models.CharField(max_length=30, db_index=True)
    full_name = models.CharField(max_length=200, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

class Vehicle(models.Model):
    vehicle_id = models.CharField(max_length=20, unique=True, default=vehicle_id)
    customer = models.ForeignKey(Customer, on_delete=models.PROTECT, related_name="vehicles")
    registration_type = models.CharField(max_length=30)
    plate_no = models.CharField(max_length=30)
    brand = models.CharField(max_length=100)
    model = models.CharField(max_length=100)
    year = models.PositiveIntegerField()
    vehicle_value = models.DecimalField(max_digits=12, decimal_places=2)
    status = models.CharField(max_length=20, default="ACTIVE")
    created_at = models.DateTimeField(auto_now_add=True)

class Quote(models.Model):
    quote_id = models.CharField(max_length=20, unique=True, default=quote_id)
    customer = models.ForeignKey(Customer, on_delete=models.PROTECT)
    vehicle = models.ForeignKey(Vehicle, on_delete=models.PROTECT)
    status = models.CharField(max_length=20, default="OPEN")
    selected_offer_id = models.CharField(max_length=20, blank=True)
    expires_at = models.DateTimeField()
    created_at = models.DateTimeField(auto_now_add=True)

class Offer(models.Model):
    offer_id = models.CharField(max_length=20, unique=True, default=offer_id)
    quote = models.ForeignKey(Quote, on_delete=models.CASCADE, related_name="offers")
    provider = models.CharField(max_length=100, default="Mock Concord")
    product = models.CharField(max_length=100)
    premium = models.DecimalField(max_digits=12, decimal_places=2)
    deductible = models.DecimalField(max_digits=12, decimal_places=2)
    coverage_amount = models.DecimalField(max_digits=12, decimal_places=2)
    currency = models.CharField(max_length=3, default="SAR")

class Order(models.Model):
    order_id = models.CharField(max_length=20, unique=True, default=order_id)
    customer = models.ForeignKey(Customer, on_delete=models.PROTECT)
    vehicle = models.ForeignKey(Vehicle, on_delete=models.PROTECT)
    quote = models.ForeignKey(Quote, on_delete=models.PROTECT)
    selected_offer_id = models.CharField(max_length=20)
    offer_snapshot = models.JSONField()
    premium = models.DecimalField(max_digits=12, decimal_places=2)
    status = models.CharField(max_length=30, default="PENDING_PAYMENT")
    created_at = models.DateTimeField(auto_now_add=True)

class Invoice(models.Model):
    invoice_id = models.CharField(max_length=20, unique=True, default=invoice_id)
    order = models.OneToOneField(Order, on_delete=models.PROTECT, related_name="invoice")
    amount = models.DecimalField(max_digits=12, decimal_places=2)
    currency = models.CharField(max_length=3, default="SAR")
    status = models.CharField(max_length=20, default="UNPAID")
    payment_url = models.URLField()
    created_at = models.DateTimeField(auto_now_add=True)
    paid_at = models.DateTimeField(null=True, blank=True)

class Payment(models.Model):
    payment_id = models.CharField(max_length=20, unique=True, default=payment_id)
    invoice = models.ForeignKey(Invoice, on_delete=models.PROTECT, related_name="payments")
    status = models.CharField(max_length=20)
    amount = models.DecimalField(max_digits=12, decimal_places=2)
    created_at = models.DateTimeField(auto_now_add=True)

class Policy(models.Model):
    policy_id = models.CharField(max_length=20, unique=True, default=policy_id)
    policy_number = models.CharField(max_length=40, unique=True)
    order = models.OneToOneField(Order, on_delete=models.PROTECT, related_name="policy")
    status = models.CharField(max_length=20, default="ACTIVE")
    start_date = models.DateField()
    end_date = models.DateField()
    coverage_amount = models.DecimalField(max_digits=12, decimal_places=2)
    deductible = models.DecimalField(max_digits=12, decimal_places=2)
    document_url = models.URLField()
    created_at = models.DateTimeField(auto_now_add=True)

class IdempotencyKey(models.Model):
    key = models.CharField(max_length=255, unique=True)
    request_hash = models.CharField(max_length=64)
    order = models.OneToOneField(Order, on_delete=models.CASCADE)
    created_at = models.DateTimeField(auto_now_add=True)
