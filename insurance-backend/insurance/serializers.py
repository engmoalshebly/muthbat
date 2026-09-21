from datetime import date
from rest_framework import serializers
from .models import Customer, Vehicle

class ApiResponseSerializer(serializers.Serializer):
    success = serializers.BooleanField()
    data = serializers.JSONField(required=False)
    error = serializers.JSONField(required=False)

class CustomerInputSerializer(serializers.ModelSerializer):
    class Meta:
        model = Customer
        fields = ["national_id", "birth_date", "phone", "full_name"]

class VehicleInputSerializer(serializers.ModelSerializer):
    customer_id = serializers.CharField(write_only=True)
    class Meta:
        model = Vehicle
        fields = ["customer_id", "registration_type", "plate_no", "brand", "model", "year", "vehicle_value"]
    def validate_year(self, value):
        if value < 1950 or value > date.today().year + 1:
            raise serializers.ValidationError("سنة المركبة غير صالحة")
        return value
    def validate_vehicle_value(self, value):
        if value <= 0:
            raise serializers.ValidationError("قيمة المركبة يجب أن تكون أكبر من صفر")
        return value

class QuoteInputSerializer(serializers.Serializer):
    customer_id = serializers.CharField()
    vehicle_id = serializers.CharField()

class SelectOfferSerializer(serializers.Serializer):
    offer_id = serializers.CharField()

class OrderInputSerializer(serializers.Serializer):
    customer_id = serializers.CharField()
    vehicle_id = serializers.CharField()
    quote_id = serializers.CharField()
    offer_id = serializers.CharField()

class PolicyInputSerializer(serializers.Serializer):
    order_id = serializers.CharField()
