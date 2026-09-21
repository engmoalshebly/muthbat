from django.contrib.auth import get_user_model
from rest_framework.test import APITestCase

class FullInsuranceFlowTests(APITestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user("tester", password="pass")
        self.client.force_authenticate(self.user)

    def test_complete_flow_and_idempotency(self):
        c = self.client.post("/api/v1/customers", {"national_id": "1234567890", "birth_date": "1995-05-18", "phone": "967777123456", "full_name": "Mohammed Ahmed"}, format="json").data["data"]
        v = self.client.post("/api/v1/vehicles", {"customer_id": c["customer_id"], "registration_type": "PRIVATE", "plate_no": "12345", "brand": "Toyota", "model": "Prado", "year": 2022, "vehicle_value": 85000}, format="json").data["data"]
        q = self.client.post("/api/v1/quotes", {"customer_id": c["customer_id"], "vehicle_id": v["vehicle_id"]}, format="json").data["data"]
        offer_id = q["offers"][1]["offer_id"]
        self.assertEqual(self.client.post(f'/api/v1/quotes/{q["quote_id"]}/select', {"offer_id": offer_id}, format="json").status_code, 200)
        payload = {"customer_id": c["customer_id"], "vehicle_id": v["vehicle_id"], "quote_id": q["quote_id"], "offer_id": offer_id}
        headers = {"HTTP_IDEMPOTENCY_KEY": "test-key-1"}
        first = self.client.post("/api/v1/orders", payload, format="json", **headers)
        second = self.client.post("/api/v1/orders", payload, format="json", **headers)
        self.assertEqual(first.data["data"]["order_id"], second.data["data"]["order_id"])
        order, invoice = first.data["data"]["order_id"], first.data["data"]["invoice"]["invoice_id"]
        self.assertEqual(self.client.post("/api/v1/policies", {"order_id": order}, format="json").status_code, 409)
        self.client.post(f"/api/v1/testing/payments/{invoice}/success")
        policy = self.client.post("/api/v1/policies", {"order_id": order}, format="json")
        self.assertEqual(policy.status_code, 201)
        self.assertEqual(policy.data["data"]["status"], "ACTIVE")

        other = get_user_model().objects.create_user("idempotency-other", password="pass")
        self.client.force_authenticate(other)
        reused = self.client.post("/api/v1/orders", payload, format="json", **headers)
        self.assertEqual(reused.status_code, 409)
        self.assertEqual(reused.data["error"]["code"], "IDEMPOTENCY_KEY_IN_USE")

    def test_customer_data_is_isolated_between_authenticated_users(self):
        response = self.client.post(
            "/api/v1/customers",
            {
                "national_id": "9876543210",
                "birth_date": "1990-01-01",
                "phone": "967777000111",
                "full_name": "Private Customer",
            },
            format="json",
        )
        customer_id = response.data["data"]["customer_id"]

        other = get_user_model().objects.create_user("other-user", password="pass")
        self.client.force_authenticate(other)

        self.assertEqual(self.client.get(f"/api/v1/customers/{customer_id}").status_code, 404)
        self.assertEqual(
            self.client.post(
                "/api/v1/vehicles",
                {
                    "customer_id": customer_id,
                    "registration_type": "PRIVATE",
                    "plate_no": "99999",
                    "brand": "Toyota",
                    "model": "Camry",
                    "year": 2022,
                    "vehicle_value": 50000,
                },
                format="json",
            ).status_code,
            404,
        )
