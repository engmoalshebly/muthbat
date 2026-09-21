from decimal import Decimal, ROUND_HALF_UP

class InsuranceProvider:
    def search_offers(self, vehicle):
        raise NotImplementedError

class MockConcordProvider(InsuranceProvider):
    def search_offers(self, vehicle):
        factor = Decimal("0.95") if vehicle.year >= 2024 else Decimal("1.00") if vehicle.year >= 2020 else Decimal("1.15")
        base = vehicle.vehicle_value * Decimal("0.018") * factor
        plans = [
            ("Comprehensive Basic", Decimal("0.85"), Decimal("500")),
            ("Comprehensive Plus", Decimal("1.00"), Decimal("250")),
            ("Comprehensive Premium", Decimal("1.25"), Decimal("0")),
        ]
        return [{"product": name, "premium": (base * multiplier).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP), "deductible": deductible} for name, multiplier, deductible in plans]
