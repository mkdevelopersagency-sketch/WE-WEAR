-- ============================================================
-- WE WEAR - SUPABASE DATABASE SETUP
-- ============================================================

-- 1. PRODUCTS
create table if not exists public.products (
    id uuid primary key,
    name text not null,
    price numeric(12,2) not null default 0 check (price >= 0),
    stock integer not null default 0 check (stock >= 0),
    category text not null,
    size text not null,
    condition text not null,
    description text default '',
    image_url text default '',
    created_at timestamptz not null default now()
);

-- 2. ORDERS
create table if not exists public.orders (
    id uuid primary key default gen_random_uuid(),
    customer_name text not null,
    customer_email text not null,
    customer_phone text not null,
    customer_city text not null,
    customer_address text not null,
    items jsonb not null default '[]'::jsonb,
    subtotal numeric(12,2) not null default 0,
    delivery_fee numeric(12,2) not null default 300,
    total numeric(12,2) not null default 0,
    status text not null default 'Pending',
    created_at timestamptz not null default now(),

    constraint orders_status_check
    check (status in (
        'Pending',
        'Confirmed',
        'Shipped',
        'Delivered',
        'Cancelled'
    ))
);

-- ============================================================
-- 3. ENABLE ROW LEVEL SECURITY
-- ============================================================

alter table public.products enable row level security;
alter table public.orders enable row level security;

-- ============================================================
-- 4. PRODUCTS POLICIES
-- ============================================================

-- Everyone can see products.
drop policy if exists "Public can view products" on public.products;

create policy "Public can view products"
on public.products
for select
to anon, authenticated
using (true);


-- Only the WE WEAR admin can add products.
drop policy if exists "Admin can insert products" on public.products;

create policy "Admin can insert products"
on public.products
for insert
to authenticated
with check (
    (auth.jwt() ->> 'email') = 'wewearadmin@gmail.com'
);


-- Only the WE WEAR admin can update products.
drop policy if exists "Admin can update products" on public.products;

create policy "Admin can update products"
on public.products
for update
to authenticated
using (
    (auth.jwt() ->> 'email') = 'wewearadmin@gmail.com'
)
with check (
    (auth.jwt() ->> 'email') = 'wewearadmin@gmail.com'
);


-- Only the WE WEAR admin can delete products.
drop policy if exists "Admin can delete products" on public.products;

create policy "Admin can delete products"
on public.products
for delete
to authenticated
using (
    (auth.jwt() ->> 'email') = 'wewearadmin@gmail.com'
);


-- ============================================================
-- 5. ORDERS POLICIES
-- ============================================================

-- Admin can view orders.
drop policy if exists "Admin can view orders" on public.orders;

create policy "Admin can view orders"
on public.orders
for select
to authenticated
using (
    (auth.jwt() ->> 'email') = 'wewearadmin@gmail.com'
);


-- Admin can update order status.
drop policy if exists "Admin can update orders" on public.orders;

create policy "Admin can update orders"
on public.orders
for update
to authenticated
using (
    (auth.jwt() ->> 'email') = 'wewearadmin@gmail.com'
)
with check (
    (auth.jwt() ->> 'email') = 'wewearadmin@gmail.com'
);


-- ============================================================
-- 6. STORAGE BUCKET
-- ============================================================

insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do update
set public = true;


-- Anyone can view product images.
drop policy if exists "Public can view product images"
on storage.objects;

create policy "Public can view product images"
on storage.objects
for select
to anon, authenticated
using (
    bucket_id = 'product-images'
);


-- Only WE WEAR admin can upload product images.
drop policy if exists "Admin can upload product images"
on storage.objects;

create policy "Admin can upload product images"
on storage.objects
for insert
to authenticated
with check (
    bucket_id = 'product-images'
    and (auth.jwt() ->> 'email') = 'wewearadmin@gmail.com'
);


-- Only WE WEAR admin can update product images.
drop policy if exists "Admin can update product images"
on storage.objects;

create policy "Admin can update product images"
on storage.objects
for update
to authenticated
using (
    bucket_id = 'product-images'
    and (auth.jwt() ->> 'email') = 'wewearadmin@gmail.com'
)
with check (
    bucket_id = 'product-images'
    and (auth.jwt() ->> 'email') = 'wewearadmin@gmail.com'
);


-- Only WE WEAR admin can delete product images.
drop policy if exists "Admin can delete product images"
on storage.objects;

create policy "Admin can delete product images"
on storage.objects
for delete
to authenticated
using (
    bucket_id = 'product-images'
    and (auth.jwt() ->> 'email') = 'wewearadmin@gmail.com'
);


-- ============================================================
-- 7. SECURE ORDER FUNCTION
-- ============================================================

create or replace function public.place_order(
    p_customer_name text,
    p_customer_email text,
    p_customer_phone text,
    p_customer_city text,
    p_customer_address text,
    p_items jsonb,
    p_subtotal numeric,
    p_delivery_fee numeric,
    p_total numeric
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    new_order_id uuid;
    item jsonb;
    product_row public.products%rowtype;
    requested_qty integer;
begin

    -- Basic validation
    if p_customer_name is null or trim(p_customer_name) = '' then
        raise exception 'Customer name is required';
    end if;

    if p_customer_phone is null or trim(p_customer_phone) = '' then
        raise exception 'Customer phone is required';
    end if;

    if p_customer_address is null or trim(p_customer_address) = '' then
        raise exception 'Customer address is required';
    end if;

    if p_items is null
       or jsonb_typeof(p_items) <> 'array'
       or jsonb_array_length(p_items) = 0 then
        raise exception 'Order must contain at least one product';
    end if;

    -- Lock/check every product and verify stock.
    for item in
        select * from jsonb_array_elements(p_items)
    loop

        requested_qty := greatest(
            1,
            coalesce((item ->> 'quantity')::integer, 1)
        );

        select *
        into product_row
        from public.products
        where id = (item ->> 'product_id')::uuid
        for update;

        if not found then
            raise exception 'Product no longer exists';
        end if;

        if product_row.stock < requested_qty then
            raise exception
                'Not enough stock for product: %',
                product_row.name;
        end if;

    end loop;

    -- Create the order.
    insert into public.orders (
        customer_name,
        customer_email,
        customer_phone,
        customer_city,
        customer_address,
        items,
        subtotal,
        delivery_fee,
        total,
        status
    )
    values (
        p_customer_name,
        p_customer_email,
        p_customer_phone,
        p_customer_city,
        p_customer_address,
        p_items,
        p_subtotal,
        p_delivery_fee,
        p_total,
        'Pending'
    )
    returning id into new_order_id;


    -- Reduce stock.
    for item in
        select * from jsonb_array_elements(p_items)
    loop

        requested_qty := greatest(
            1,
            coalesce((item ->> 'quantity')::integer, 1)
        );

        update public.products
        set stock = stock - requested_qty
        where id = (item ->> 'product_id')::uuid;

    end loop;


    return new_order_id;

end;
$$;


-- ============================================================
-- 8. ALLOW WEBSITE TO CALL THE ORDER FUNCTION
-- ============================================================

grant execute on function public.place_order(
    text,
    text,
    text,
    text,
    text,
    jsonb,
    numeric,
    numeric,
    numeric
) to anon, authenticated;


-- ============================================================
-- DONE
-- ============================================================
