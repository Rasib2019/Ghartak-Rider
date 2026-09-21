# GHAR TAK — Rider App

Mobile-first web app for riders: sign in with an email code, go online/offline,
accept assigned orders, pick up, deliver (with delivery code and COD cash),
and see today's earnings and cash in hand. Uses the same Supabase project as the
Ops Portal and the Customer App.


## 1. Database (run once)

Supabase Dashboard -> SQL Editor -> paste all of `supabase/rider_app.sql` -> Run.

The app never reads or edits the `orders` table directly. It only calls four
secure functions (`rider_me`, `rider_my_orders`, `rider_set_online`,
`rider_update_order`), which check that the caller is an approved, active rider
and that the order is assigned to them.

## 2. Environment variables

Copy `.env.example` to `.env` and fill the same values the Customer App uses:

```
VITE_SUPABASE_URL=https://zdqwrkfcbewsxptdohsd.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=...
```

## 3. Run locally

```
npm install
npm run dev
```

## 4. Deploy on Cloudflare Pages

Create a new Pages project from the GitHub repo:

- Framework preset: Vite (or None)
- Build command: `npm run build`
- Build output directory: `dist`
- Environment variables: the two `VITE_...` values above

## How riders get an account

Riders cannot sign themselves up. A Super Admin / Operations Admin adds them in the
Ops Portal (Riders -> "+ Add rider"). The rider then signs in here with that email
and a 6-digit code. Make sure Supabase Authentication -> Emails -> Magic Link template
contains `{{ .Token }}` (same requirement as the Customer App).

## Order flow in this app

assigned -> Accept -> picked up -> start delivery -> delivered (or failed with a reason).
Reject sends the order back to the office to assign to someone else.
When an order is delivered and has COD, the cash is recorded against the rider
(shown as "Cash in hand") until Finance settles it in the portal.

The list refreshes every 20 seconds and whenever the app comes back to the foreground.

## Not included yet

- GPS location sharing / live tracking
- Push notifications (a banner + vibration appears only while the app is open)
- Automatic dispatch (orders are still assigned by staff from the portal)
- Delivery code: enforced only for orders that have `delivery_otp` set. The customer
  app does not generate or show one yet.
