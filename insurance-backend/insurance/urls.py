from django.conf import settings
from django.urls import path
from . import views

urlpatterns = [
    path("health", views.health),
    path("customers", views.customers), path("customers/<str:id>", views.customer_detail),
    path("vehicles", views.vehicles), path("vehicles/<str:id>", views.vehicle_detail),
    path("quotes", views.quotes), path("quotes/<str:id>", views.quote_detail), path("quotes/<str:id>/select", views.select_offer),
    path("orders", views.orders), path("orders/<str:id>", views.order_detail), path("orders/<str:id>/status", views.order_status),
    path("invoices/<str:id>", views.invoice_detail), path("invoices/<str:id>/payment-status", views.payment_status),
    path("policies", views.policies), path("policies/<str:id>", views.policy_detail),
]

# Test payment mutation endpoints are not registered when the service is
# configured outside the isolated demo mode.
if settings.ENABLE_TEST_PAYMENTS:
    urlpatterns += [
        path("testing/payments/<str:id>/success", views.payment_success),
        path("testing/payments/<str:id>/fail", views.payment_fail),
    ]
