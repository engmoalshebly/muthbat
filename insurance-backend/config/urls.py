from django.urls import include, path
from drf_spectacular.views import SpectacularAPIView, SpectacularSwaggerView
from rest_framework_simplejwt.views import TokenObtainPairView, TokenRefreshView

urlpatterns = [
    path("api/v1/auth/token", TokenObtainPairView.as_view(), name="token"),
    path("api/v1/auth/token/refresh", TokenRefreshView.as_view(), name="token-refresh"),
    path("api/v1/", include("insurance.urls")),
    path("api/schema/", SpectacularAPIView.as_view(), name="schema"),
    path("api/docs/", SpectacularSwaggerView.as_view(url_name="schema"), name="swagger-ui"),
]
