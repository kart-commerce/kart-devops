#!/usr/bin/env python3
"""Seeds customers, wishlists, carts, orders+payments, offers, and a few admin actions across the
local-dev kart-commerce stack -- via the real HTTP APIs only (same principle as catalog-seed.sh:
Postgres write-side, Mongo read-side, and every consumer in between all get exercised for real,
instead of a raw SQL insert that only one of those three would ever see).

Run this AFTER scripts/catalog-seed.sh (or scripts/seed-everything.sh, which runs both) -- orders
need real SKUs with real inventory already provisioned.

Re-run safety:
  - Customers are named deterministically (seed.customer001@example.com, ...) and this script
    logs in rather than re-registering if an account already exists -- safe to re-run without
    growing the customer count.
  - Orders/payments/coupons/promotions/shipment-requests are scoped to a per-run id (RUN_ID below,
    override with SEED_RUN_ID) baked into their Idempotency-Key/coupon-code, so re-running this
    script adds a fresh batch of transactional data each time rather than idempotently replaying
    (or 409-conflicting on) the previous run's.
  - Wishlist/cart adds have no idempotency key -- they're naturally additive (wishlist duplicates
    are harmless, cart quantities just increment) -- re-running adds a bit more of each, which is
    fine for dummy data.

Requires: python3 -m pip install requests (only if not already installed).

Usage:
  scripts/platform-seed.py                       # defaults: 60 customers, 150 orders
  SEED_CUSTOMER_COUNT=20 SEED_ORDER_COUNT=50 scripts/platform-seed.py
"""
import base64
import json
import os
import random
import sys
import time
import uuid
from pathlib import Path

try:
    import requests
except ImportError:
    print("This script needs the 'requests' package: python3 -m pip install requests", file=sys.stderr)
    sys.exit(1)

DEVOPS_ROOT = Path(__file__).resolve().parent.parent
CATALOG_DATA_FILE = DEVOPS_ROOT / "scripts" / "catalog-seed-data-500.json"

RUN_ID = os.environ.get("SEED_RUN_ID", time.strftime("%Y%m%d%H%M%S"))
CUSTOMER_COUNT = int(os.environ.get("SEED_CUSTOMER_COUNT", "60"))
ORDER_COUNT = int(os.environ.get("SEED_ORDER_COUNT", "150"))
CUSTOMER_PASSWORD = "SeedPass123!"

PORTS = {}
for _line in open(DEVOPS_ROOT / "ports.env"):
    _line = _line.strip()
    if _line and not _line.startswith("#") and "=" in _line:
        k, v = _line.split("=", 1)
        PORTS[k] = v

IDENTITY = f"http://localhost:{PORTS['IDENTITY_PORT']}"
ORDER = f"http://localhost:{PORTS['ORDER_PORT']}"
PAYMENT = f"http://localhost:{PORTS['PAYMENT_PORT']}"
WISHLIST = f"http://localhost:{PORTS['WISHLIST_PORT']}"
CART = f"http://localhost:{PORTS['CART_PORT']}"
OFFER = f"http://localhost:{PORTS['OFFER_PORT']}"

session = requests.Session()


def new_idem():
    return str(uuid.uuid4())


def jwt_claims(token):
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def get_admin_token():
    r = session.post(f"{IDENTITY}/v1/auth/token", data={
        "grant_type": "client_credentials", "client_id": "admin-service",
        "client_secret": "dev-admin-service-client-secret", "scope": "admin",
    })
    r.raise_for_status()
    return r.json()["accessToken"]


def register_or_login(email, password):
    r = session.post(f"{IDENTITY}/v1/auth/register", json={
        "email": email, "password": password, "displayName": email.split("@")[0],
    })
    if r.status_code == 409:
        r = session.post(f"{IDENTITY}/v1/auth/login", json={"email": email, "password": password})
    r.raise_for_status()
    token = r.json()["accessToken"]
    return token, jwt_claims(token)["sub"]


def load_skus():
    if not CATALOG_DATA_FILE.exists():
        print(f"Catalog data file not found: {CATALOG_DATA_FILE}\n"
              f"Run scripts/catalog-seed.sh scripts/catalog-seed-data-500.json first "
              f"(or scripts/seed-everything.sh, which does both).", file=sys.stderr)
        sys.exit(1)
    data = json.load(open(CATALOG_DATA_FILE))
    skus = []
    for p in data["products"]:
        for v in p["variants"]:
            skus.append({"sku": f"{p['sku']}-{v['suffix']}", "price": v["price"]})
    return skus


def main():
    print(f"== Run id: {RUN_ID} (customers={CUSTOMER_COUNT}, orders={ORDER_COUNT}) ==")

    print("== Loading catalog SKUs ==")
    skus = load_skus()
    print(f"  {len(skus)} SKUs available")

    print("== Registering/logging in customers ==")
    customers = []
    for i in range(1, CUSTOMER_COUNT + 1):
        email = f"seed.customer{i:03d}@example.com"
        try:
            token, user_id = register_or_login(email, CUSTOMER_PASSWORD)
            customers.append({"email": email, "password": CUSTOMER_PASSWORD, "token": token, "userId": user_id, "issued": time.time()})
        except Exception as e:
            print(f"  FAILED customer {email}: {e}")
    print(f"  {len(customers)} customers ready")

    def fresh_token(c):
        # access tokens last 900s -- re-login if older than 12 minutes to stay safe over a long run
        if time.time() - c["issued"] > 720:
            c["token"], _ = register_or_login(c["email"], c["password"])
            c["issued"] = time.time()
        return c["token"]

    print("== Wishlist adds ==")
    wl_ok = wl_fail = 0
    for c in customers:
        if random.random() < 0.7:
            for sku in random.sample(skus, k=random.randint(2, 5)):
                r = session.post(f"{WISHLIST}/v1/wishlist", json={"sku": sku["sku"]},
                                  headers={"Authorization": f"Bearer {fresh_token(c)}"})
                if r.status_code < 300:
                    wl_ok += 1
                else:
                    wl_fail += 1
    print(f"  wishlist: {wl_ok} ok, {wl_fail} failed")

    print("== Cart adds (some left abandoned, matching real checkout drop-off) ==")
    cart_ok = cart_fail = 0
    for c in customers:
        if random.random() < 0.6:
            for sku in random.sample(skus, k=random.randint(1, 4)):
                r = session.post(f"{CART}/v1/cart/items", json={"sku": sku["sku"], "quantity": random.randint(1, 3)},
                                  headers={"Authorization": f"Bearer {fresh_token(c)}"})
                if r.status_code < 300:
                    cart_ok += 1
                else:
                    cart_fail += 1
    print(f"  cart: {cart_ok} ok, {cart_fail} failed")

    print("== Offers: coupons + promotions (admin) ==")
    admin_token = get_admin_token()
    coupon_codes = []
    for i in range(1, 9):
        code = f"SEED{RUN_ID}{i:02d}"
        r = session.post(f"{OFFER}/v1/coupons", json={
            "couponCode": code, "perUserCap": 1, "globalCap": 500,
            "validFrom": "2026-08-01T00:00:00Z", "validUntil": "2027-08-01T00:00:00Z",
        }, headers={"Authorization": f"Bearer {admin_token}", "Idempotency-Key": new_idem()})
        if r.status_code < 300:
            coupon_codes.append(code)
        else:
            print(f"  coupon {code} FAILED ({r.status_code}): {r.text[:150]}")
    promo_ok = 0
    for i in range(1, 5):
        r = session.post(f"{OFFER}/v1/promotions", json={
            "startsAt": "2026-08-01T00:00:00Z", "endsAt": "2027-08-01T00:00:00Z",
            "discountRule": {"type": "percentageOff", "value": random.choice([10, 15, 20, 25])},
        }, headers={"Authorization": f"Bearer {admin_token}", "Idempotency-Key": new_idem()})
        if r.status_code < 300:
            promo_ok += 1
        else:
            print(f"  promotion {i} FAILED ({r.status_code}): {r.text[:150]}")
    print(f"  {len(coupon_codes)} coupons, {promo_ok} promotions created")

    print("== Placing orders (phase A: create) ==")
    orders = []
    for i in range(1, ORDER_COUNT + 1):
        c = random.choice(customers)
        chosen = random.sample(skus, k=random.randint(1, 3))
        items = [{"sku": s["sku"], "qty": random.randint(1, 2), "unitPrice": {"amount": s["price"], "currency": "USD"}} for s in chosen]
        total = sum(it["unitPrice"]["amount"] * it["qty"] for it in items)
        r = session.post(f"{ORDER}/v1/orders", json={"userId": c["userId"], "items": items, "currency": "USD"},
                          headers={"Authorization": f"Bearer {fresh_token(c)}", "Idempotency-Key": f"seed-{RUN_ID}-order-{i:04d}"})
        if r.status_code < 300:
            orders.append({"orderId": r.json()["orderId"], "customer": c, "amount": total})
        else:
            print(f"  order {i} FAILED ({r.status_code}): {r.text[:200]}")
        if i % 25 == 0:
            print(f"  ...{i}/{ORDER_COUNT} orders created")

    # Inventory's outbox relay polls every 5s before an order can advance Created->Reserved --
    # charging before that lands hits a known bug in the retry-tier's routing-key handling
    # (loses the original routing key on redelivery, so a same-second retry never actually
    # succeeds) -- waiting here avoids ever needing that retry path at all.
    print(f"  {len(orders)} orders created; waiting 12s for inventory-reserved events to land")
    time.sleep(12)

    print("== Charging payments (phase B) ==")
    paid, declined, timeout_ct, pay_fail = [], 0, 0, 0
    for i, o in enumerate(orders, 1):
        roll = random.random()
        gw_token = "tok_good" if roll < 0.85 else ("tok_decline_seed" if roll < 0.95 else "tok_timeout_seed")
        r = session.post(f"{PAYMENT}/v1/payments/charge", json={
            "orderId": o["orderId"], "amount": {"amount": round(o["amount"], 2), "currency": "USD"}, "gatewayToken": gw_token,
        }, headers={"Authorization": f"Bearer {fresh_token(o['customer'])}", "Idempotency-Key": f"seed-{RUN_ID}-pay-{i:04d}"})
        if r.status_code < 300 and r.json().get("status") == "completed":
            paid.append(o)
        elif gw_token.startswith("tok_decline"):
            declined += 1
        elif gw_token.startswith("tok_timeout"):
            timeout_ct += 1
        else:
            pay_fail += 1
        if i % 25 == 0:
            print(f"  ...{i}/{len(orders)} payments attempted")
    print(f"  paid={len(paid)} declined={declined} timeout={timeout_ct} other_fail={pay_fail}")

    # Same async-latency reason as the wait above: the order only flips Reserved->Paid once it
    # consumes payment-service's own PaymentCompleted event off its outbox relay -- request-shipment
    # 409s ("must be Paid") if called before that lands. A large batch's own charge-loop runtime
    # usually covers this by accident; a small batch (or the first few orders of a large one) won't.
    print("  waiting 8s for PaymentCompleted events to land before shipping actions")
    time.sleep(8)

    print("== Admin: shipping address + request-shipment for paid orders ==")
    # NOTE: kart-shipping-service isn't deployed in this stack, so delivery-tracking-service never
    # sees a ShipmentDispatched event for these -- the saga's own reconciliation sweep will move
    # these to FulfillmentException after ~120s. That's the saga behaving correctly given the
    # missing downstream service, not a bug in this script.
    ship_ok = 0
    for i, o in enumerate(paid, 1):
        addr = {
            "recipientName": o["customer"]["email"].split("@")[0],
            "line1": f"{random.randint(100,9999)} Market St", "city": "Springfield",
            "state": "IL", "postalCode": "62704", "country": "US", "phone": "555-0100",
        }
        session.patch(f"{ORDER}/v1/orders/{o['orderId']}/shipping-address", json=addr,
                       headers={"Authorization": f"Bearer {admin_token}", "Idempotency-Key": new_idem()})
        r = session.post(f"{ORDER}/v1/orders/{o['orderId']}/request-shipment",
                          headers={"Authorization": f"Bearer {admin_token}", "Idempotency-Key": new_idem()})
        if r.status_code < 300:
            ship_ok += 1
    print(f"  {ship_ok}/{len(paid)} shipment requests recorded")

    print("\n== SUMMARY ==")
    print(f"run id: {RUN_ID}")
    print(f"customers: {len(customers)}")
    print(f"wishlist adds: {wl_ok}")
    print(f"cart adds: {cart_ok}")
    print(f"coupons: {len(coupon_codes)}  promotions: {promo_ok}")
    print(f"orders created: {len(orders)}")
    print(f"orders paid: {len(paid)}  declined: {declined}  timeout: {timeout_ct}")
    print(f"shipment requests: {ship_ok}")


if __name__ == "__main__":
    main()
