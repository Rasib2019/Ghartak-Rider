-- =====================================================================
-- GHAR TAK Rider App — secure server functions
-- Run ONCE in Supabase SQL Editor (safe to re-run).
--
-- The rider app never reads or updates the orders table directly.
-- It only calls these functions, which check that the caller is an
-- approved, active rider and that the order is assigned to them.
-- (This also keeps orders.delivery_otp hidden from the rider.)
-- =====================================================================

-- Internal: checks the caller is a rider. Returns the rider's user id.
create or replace function public._rider_guard(p_require_approved boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  u_role text;
  u_status text;
  r_status text;
begin
  if uid is null then
    raise exception 'Not signed in';
  end if;

  select role::text, status::text into u_role, u_status from public.users where id = uid;
  if u_role is null or u_role <> 'rider' then
    raise exception 'This account is not a rider account';
  end if;
  if u_status <> 'active' then
    raise exception 'Your account is not active';
  end if;

  select approval_status::text into r_status from public.riders where user_id = uid;
  if r_status is null then
    raise exception 'Rider profile not found';
  end if;
  if p_require_approved and r_status <> 'approved' then
    raise exception 'Your rider account is %', r_status;
  end if;

  return uid;
end;
$$;

-- Internal: rider's share of a delivery fare, using the zone's payout %.
create or replace function public._rider_earning(p_fare numeric, p_zone uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(p_fare, 0)
       * coalesce((select pr.rider_payout_pct from public.pricing_rules pr
                   where pr.zone_id = p_zone and pr.is_active limit 1), 0)
       / 100.0;
$$;

-- Rider's own profile + today's numbers (works for pending riders too).
create or replace function public.rider_me()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := public._rider_guard(false);
  day_start timestamptz := date_trunc('day', now() at time zone 'Asia/Karachi') at time zone 'Asia/Karachi';
begin
  return (
    select jsonb_build_object(
      'id', u.id,
      'full_name', u.full_name,
      'phone', u.phone,
      'vehicle_type', r.vehicle_type,
      'vehicle_number', r.vehicle_number,
      'is_online', r.is_online,
      'approval_status', r.approval_status::text,
      'cod_in_hand', coalesce((
        select sum(c.amount) from public.cod_transactions c
        where c.collected_by = uid and c.collection_status::text = 'collected'
      ), 0),
      'delivered_today', (
        select count(*) from public.orders o
        where o.rider_id = uid and o.status::text in ('delivered', 'completed') and o.updated_at >= day_start
      ),
      'earnings_today', coalesce((
        select round(sum(public._rider_earning(o.fare_amount, o.zone_id)), 0) from public.orders o
        where o.rider_id = uid and o.status::text in ('delivered', 'completed') and o.updated_at >= day_start
      ), 0)
    )
    from public.users u
    join public.riders r on r.user_id = u.id
    where u.id = uid
  );
end;
$$;

-- Orders assigned to the calling rider (latest 100). delivery_otp is never returned.
create or replace function public.rider_my_orders()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := public._rider_guard(true);
begin
  return coalesce((
    select jsonb_agg(x.j order by x.created_at desc)
    from (
      select
        o.created_at,
        jsonb_build_object(
          'id', o.id,
          'order_number', o.order_number,
          'status', o.status::text,
          'created_at', o.created_at,
          'updated_at', o.updated_at,
          'category', o.category,
          'notes', o.notes,
          'contact_name', o.contact_name,
          'contact_phone', o.contact_phone,
          'customer_name', cu.full_name,
          'customer_phone', cu.phone,
          'pickup_address', pa.address_text,
          'drop_address', da.address_text,
          'zone_name', z.name,
          'distance_km', o.distance_km,
          'fare_amount', o.fare_amount,
          'cod_amount', o.cod_amount,
          'rider_earning', round(public._rider_earning(o.fare_amount, o.zone_id), 0),
          'requires_otp', (o.delivery_otp is not null),
          'failure_reason', o.failure_reason
        ) as j
      from public.orders o
      left join public.users cu on cu.id = o.customer_id
      left join public.addresses pa on pa.id = o.pickup_address_id
      left join public.addresses da on da.id = o.drop_address_id
      left join public.zones z on z.id = o.zone_id
      where o.rider_id = uid
      order by o.created_at desc
      limit 100
    ) x
  ), '[]'::jsonb);
end;
$$;

-- Online / offline switch.
create or replace function public.rider_set_online(p_online boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := public._rider_guard(true);
begin
  update public.riders set is_online = p_online, updated_at = now() where user_id = uid;
end;
$$;

-- Move an order forward.
-- p_action: accept | reject | pickup | start | deliver | fail
create or replace function public.rider_update_order(
  p_order_id uuid,
  p_action text,
  p_otp text default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := public._rider_guard(true);
  o record;
  new_status text;
  hist_reason text := null;
begin
  select * into o from public.orders where id = p_order_id and rider_id = uid for update;
  if not found then
    raise exception 'Order not found or not assigned to you';
  end if;

  if p_action = 'accept' then
    if o.status::text <> 'assigned' then raise exception 'This order cannot be accepted now'; end if;
    new_status := 'accepted';

  elsif p_action = 'reject' then
    if o.status::text not in ('assigned', 'accepted') then raise exception 'This order can no longer be rejected'; end if;
    new_status := 'created';
    hist_reason := coalesce(nullif(trim(p_note), ''), 'Rejected by rider');

  elsif p_action = 'pickup' then
    if o.status::text not in ('accepted', 'arriving_pickup') then raise exception 'Accept the order first'; end if;
    new_status := 'picked_up';

  elsif p_action = 'start' then
    if o.status::text <> 'picked_up' then raise exception 'Mark the order as picked up first'; end if;
    new_status := 'in_transit';

  elsif p_action = 'deliver' then
    if o.status::text not in ('in_transit', 'arriving_dropoff') then raise exception 'Start the delivery first'; end if;
    if o.delivery_otp is not null and coalesce(trim(p_otp), '') <> o.delivery_otp then
      raise exception 'Incorrect delivery code';
    end if;
    new_status := 'delivered';

  elsif p_action = 'fail' then
    if o.status::text not in ('picked_up', 'in_transit', 'arriving_dropoff') then raise exception 'This order cannot be marked as failed now'; end if;
    if coalesce(trim(p_note), '') = '' then raise exception 'Please write the reason'; end if;
    new_status := 'failed';
    hist_reason := trim(p_note);

  else
    raise exception 'Unknown action';
  end if;

  if p_action = 'reject' then
    update public.orders
       set status = new_status::public.order_status, rider_id = null, updated_at = now()
     where id = o.id;
  elsif p_action = 'deliver' then
    update public.orders
       set status = new_status::public.order_status, pod_notes = nullif(trim(p_note), ''), updated_at = now()
     where id = o.id;
    -- Cash on delivery: record the cash the rider is now holding
    if coalesce(o.cod_amount, 0) > 0
       and not exists (select 1 from public.cod_transactions where order_id = o.id) then
      insert into public.cod_transactions (order_id, amount, method, collection_status, collected_by, collected_at)
      values (o.id, o.cod_amount, 'cash', 'collected', uid, now());
    end if;
  elsif p_action = 'fail' then
    update public.orders
       set status = new_status::public.order_status, failure_reason = hist_reason, updated_at = now()
     where id = o.id;
  else
    update public.orders
       set status = new_status::public.order_status, updated_at = now()
     where id = o.id;
  end if;

  insert into public.order_status_history (order_id, from_status, to_status, actor_id, actor_role, reason)
  values (o.id, o.status, new_status::public.order_status, uid, 'rider'::public.user_role, hist_reason);

  return jsonb_build_object('status', new_status);
end;
$$;

-- Only signed-in users may call the public functions; helpers stay internal.
revoke all on function public._rider_guard(boolean) from public, anon, authenticated;
revoke all on function public._rider_earning(numeric, uuid) from public, anon, authenticated;

revoke all on function public.rider_me() from public, anon;
revoke all on function public.rider_my_orders() from public, anon;
revoke all on function public.rider_set_online(boolean) from public, anon;
revoke all on function public.rider_update_order(uuid, text, text, text) from public, anon;

grant execute on function public.rider_me() to authenticated;
grant execute on function public.rider_my_orders() to authenticated;
grant execute on function public.rider_set_online(boolean) to authenticated;
grant execute on function public.rider_update_order(uuid, text, text, text) to authenticated;
