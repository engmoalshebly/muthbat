import hashlib
import json
from datetime import timedelta
from django.conf import settings
from django.db import transaction
from django.shortcuts import get_object_or_404
from django.utils import timezone
from drf_spectacular.utils import extend_schema
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from .models import Customer, Vehicle, Quote, Offer, Order, Invoice, Payment, Policy, IdempotencyKey
from .provider import MockConcordProvider
from .serializers import ApiResponseSerializer, CustomerInputSerializer, VehicleInputSerializer, QuoteInputSerializer, SelectOfferSerializer, OrderInputSerializer, PolicyInputSerializer

def ok(data, code=status.HTTP_200_OK):
    return Response({"success": True, "data": data}, status=code)

def offer_data(o):
    return {"offer_id": o.offer_id, "provider": o.provider, "product": o.product, "premium": float(o.premium), "deductible": float(o.deductible), "coverage_amount": float(o.coverage_amount), "currency": o.currency}

def invoice_data(i):
    return {"invoice_id": i.invoice_id, "order_id": i.order.order_id, "amount": float(i.amount), "currency": i.currency, "status": i.status, "payment_url": i.payment_url, "paid_at": i.paid_at}

@extend_schema(responses=ApiResponseSerializer)
@api_view(["GET"])
@permission_classes([AllowAny])
def health(request):
    return ok({"status": "healthy", "service": "mock-concord-insurance"})

@extend_schema(request=CustomerInputSerializer, responses=ApiResponseSerializer)
@api_view(["POST"])
def customers(request):
    s = CustomerInputSerializer(data=request.data); s.is_valid(raise_exception=True)
    customer = s.save(owner=request.user)
    return ok({"customer_id": customer.customer_id, "national_id": customer.national_id, "phone": customer.phone, "full_name": customer.full_name}, status.HTTP_201_CREATED)

@extend_schema(responses=ApiResponseSerializer)
@api_view(["GET"])
def customer_detail(request, id):
    c = get_object_or_404(Customer, customer_id=id, owner=request.user)
    return ok({"customer_id": c.customer_id, "national_id": c.national_id, "birth_date": c.birth_date, "phone": c.phone, "full_name": c.full_name})

@extend_schema(request=VehicleInputSerializer, responses=ApiResponseSerializer)
@api_view(["POST"])
def vehicles(request):
    s = VehicleInputSerializer(data=request.data); s.is_valid(raise_exception=True)
    c = get_object_or_404(Customer, customer_id=s.validated_data.pop("customer_id"), owner=request.user)
    v = Vehicle.objects.create(customer=c, **s.validated_data)
    return ok({"vehicle_id": v.vehicle_id, "customer_id": c.customer_id, "status": v.status}, status.HTTP_201_CREATED)

@extend_schema(responses=ApiResponseSerializer)
@api_view(["GET"])
def vehicle_detail(request, id):
    v = get_object_or_404(Vehicle, vehicle_id=id, customer__owner=request.user)
    return ok({"vehicle_id": v.vehicle_id, "customer_id": v.customer.customer_id, "registration_type": v.registration_type, "plate_no": v.plate_no, "brand": v.brand, "model": v.model, "year": v.year, "vehicle_value": float(v.vehicle_value), "status": v.status})

@extend_schema(request=QuoteInputSerializer, responses=ApiResponseSerializer)
@api_view(["POST"])
def quotes(request):
    s = QuoteInputSerializer(data=request.data); s.is_valid(raise_exception=True)
    c = get_object_or_404(Customer, customer_id=s.validated_data["customer_id"], owner=request.user)
    v = get_object_or_404(Vehicle, vehicle_id=s.validated_data["vehicle_id"], customer=c)
    with transaction.atomic():
        q = Quote.objects.create(customer=c, vehicle=v, expires_at=timezone.now() + timedelta(hours=24))
        for plan in MockConcordProvider().search_offers(v): Offer.objects.create(quote=q, coverage_amount=v.vehicle_value, **plan)
    return ok({"quote_id": q.quote_id, "status": q.status, "expires_at": q.expires_at, "offers": [offer_data(x) for x in q.offers.all()]}, status.HTTP_201_CREATED)

@extend_schema(responses=ApiResponseSerializer)
@api_view(["GET"])
def quote_detail(request, id):
    q = get_object_or_404(Quote, quote_id=id, customer__owner=request.user)
    return ok({"quote_id": q.quote_id, "customer_id": q.customer.customer_id, "vehicle_id": q.vehicle.vehicle_id, "status": q.status, "selected_offer_id": q.selected_offer_id or None, "expires_at": q.expires_at, "offers": [offer_data(x) for x in q.offers.all()]})

@extend_schema(request=SelectOfferSerializer, responses=ApiResponseSerializer)
@api_view(["POST"])
def select_offer(request, id):
    s = SelectOfferSerializer(data=request.data); s.is_valid(raise_exception=True)
    q = get_object_or_404(Quote, quote_id=id, customer__owner=request.user)
    if q.expires_at <= timezone.now(): return Response({"success": False, "error": {"code": "QUOTE_EXPIRED", "message": "انتهت صلاحية العرض"}}, status=409)
    o = get_object_or_404(Offer, quote=q, offer_id=s.validated_data["offer_id"])
    q.selected_offer_id, q.status = o.offer_id, "SELECTED"; q.save(update_fields=["selected_offer_id", "status"])
    return ok({"quote_id": q.quote_id, "selected_offer_id": o.offer_id, "status": q.status})

def order_payload(o):
    return {"order_id": o.order_id, "customer_id": o.customer.customer_id, "vehicle_id": o.vehicle.vehicle_id, "quote_id": o.quote.quote_id, "status": o.status, "selected_offer": o.offer_snapshot, "invoice": invoice_data(o.invoice)}

@extend_schema(request=OrderInputSerializer, responses=ApiResponseSerializer)
@api_view(["POST"])
def orders(request):
    s = OrderInputSerializer(data=request.data); s.is_valid(raise_exception=True)
    key = request.headers.get("Idempotency-Key")
    if not key: return Response({"success": False, "error": {"code": "IDEMPOTENCY_KEY_REQUIRED", "message": "أرسل Idempotency-Key في الترويسة"}}, status=400)
    request_hash = hashlib.sha256(json.dumps(s.validated_data, sort_keys=True).encode()).hexdigest()
    previous = IdempotencyKey.objects.filter(key=key).select_related("order__invoice").first()
    if previous:
        if previous.order.customer.owner_id != request.user.id:
            return Response({"success": False, "error": {"code": "IDEMPOTENCY_KEY_IN_USE", "message": "مفتاح التكرار مستخدم من حساب آخر"}}, status=409)
        if previous.request_hash != request_hash: return Response({"success": False, "error": {"code": "IDEMPOTENCY_CONFLICT", "message": "المفتاح مستخدم مع طلب مختلف"}}, status=409)
        return ok(order_payload(previous.order))
    d = s.validated_data
    c = get_object_or_404(Customer, customer_id=d["customer_id"], owner=request.user); v = get_object_or_404(Vehicle, vehicle_id=d["vehicle_id"], customer=c)
    q = get_object_or_404(Quote, quote_id=d["quote_id"], customer=c, vehicle=v)
    o = get_object_or_404(Offer, offer_id=d["offer_id"], quote=q)
    if q.status != "SELECTED" or q.selected_offer_id != o.offer_id: return Response({"success": False, "error": {"code": "OFFER_NOT_SELECTED", "message": "يجب اختيار العرض أولًا"}}, status=409)
    with transaction.atomic():
        order = Order.objects.create(customer=c, vehicle=v, quote=q, selected_offer_id=o.offer_id, offer_snapshot=offer_data(o), premium=o.premium)
        invoice = Invoice.objects.create(order=order, amount=o.premium, payment_url=f"{settings.PUBLIC_BASE_URL}/mock-pay/{order.order_id}")
        IdempotencyKey.objects.create(key=key, request_hash=request_hash, order=order)
    return ok(order_payload(order), status.HTTP_201_CREATED)

@extend_schema(responses=ApiResponseSerializer)
@api_view(["GET"])
def order_detail(request, id): return ok(order_payload(get_object_or_404(Order.objects.select_related("invoice"), order_id=id, customer__owner=request.user)))

@extend_schema(responses=ApiResponseSerializer)
@api_view(["GET"])
def order_status(request, id):
    o = get_object_or_404(Order, order_id=id, customer__owner=request.user); return ok({"order_id": o.order_id, "status": o.status})

@extend_schema(responses=ApiResponseSerializer)
@api_view(["GET"])
def invoice_detail(request, id): return ok(invoice_data(get_object_or_404(Invoice, invoice_id=id, order__customer__owner=request.user)))

@extend_schema(responses=ApiResponseSerializer)
@api_view(["GET"])
def payment_status(request, id):
    i = get_object_or_404(Invoice, invoice_id=id, order__customer__owner=request.user); p = i.payments.filter(status="PAID").last()
    data = {"invoice_id": i.invoice_id, "payment_status": i.status, "paid_at": i.paid_at}
    if p: data["payment_id"] = p.payment_id
    return ok(data)

@extend_schema(request=None, responses=ApiResponseSerializer)
@api_view(["POST"])
def payment_success(request, id):
    with transaction.atomic():
        i = get_object_or_404(Invoice.objects.select_for_update(), invoice_id=id, order__customer__owner=request.user)
        if i.status == "PAID": p = i.payments.filter(status="PAID").last()
        else:
            i.status, i.paid_at = "PAID", timezone.now(); i.save(update_fields=["status", "paid_at"])
            i.order.status = "PAID"; i.order.save(update_fields=["status"])
            p = Payment.objects.create(invoice=i, status="PAID", amount=i.amount)
    return ok({"invoice_id": i.invoice_id, "payment_id": p.payment_id, "status": i.status, "amount": float(i.amount)})

@extend_schema(request=None, responses=ApiResponseSerializer)
@api_view(["POST"])
def payment_fail(request, id):
    with transaction.atomic():
        i = get_object_or_404(Invoice.objects.select_for_update(), invoice_id=id, order__customer__owner=request.user)
        if i.status == "PAID": return Response({"success": False, "error": {"code": "ALREADY_PAID", "message": "الفاتورة مدفوعة بالفعل"}}, status=409)
        i.status = "FAILED"; i.save(update_fields=["status"]); Payment.objects.create(invoice=i, status="FAILED", amount=i.amount)
    return ok({"invoice_id": i.invoice_id, "status": i.status})

@extend_schema(request=PolicyInputSerializer, responses=ApiResponseSerializer)
@api_view(["POST"])
def policies(request):
    s = PolicyInputSerializer(data=request.data); s.is_valid(raise_exception=True)
    with transaction.atomic():
        o = get_object_or_404(Order.objects.select_for_update().select_related("invoice"), order_id=s.validated_data["order_id"], customer__owner=request.user)
        if hasattr(o, "policy"): return ok(policy_payload(o.policy))
        if o.status != "PAID" or o.invoice.status != "PAID": return Response({"success": False, "error": {"code": "PAYMENT_REQUIRED", "message": "لا يمكن إصدار الوثيقة قبل إثبات الدفع"}}, status=409)
        today = timezone.localdate(); snapshot = o.offer_snapshot
        p = Policy.objects.create(order=o, policy_number=f"CON-{today.year}-{o.order_id.split('-')[1]}", start_date=today, end_date=today + timedelta(days=364), coverage_amount=snapshot["coverage_amount"], deductible=snapshot["deductible"], document_url=f"{settings.PUBLIC_BASE_URL}/documents/{o.order_id}.pdf")
        o.status = "COMPLETED"; o.save(update_fields=["status"])
    return ok(policy_payload(p), status.HTTP_201_CREATED)

def policy_payload(p):
    return {"policy_id": p.policy_id, "policy_number": p.policy_number, "order_id": p.order.order_id, "customer_id": p.order.customer.customer_id, "vehicle_id": p.order.vehicle.vehicle_id, "status": p.status, "coverage": {"start_date": p.start_date, "end_date": p.end_date, "coverage_amount": float(p.coverage_amount), "deductible": float(p.deductible)}, "document_url": p.document_url}

@extend_schema(responses=ApiResponseSerializer)
@api_view(["GET"])
def policy_detail(request, id): return ok(policy_payload(get_object_or_404(Policy.objects.select_related("order__customer", "order__vehicle"), policy_id=id, order__customer__owner=request.user)))
