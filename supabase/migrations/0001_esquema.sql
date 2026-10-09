create extension if not exists vector;
create extension if not exists pg_trgm;

create sequence seq_codigo_producto start 1;

create table modelos (
  id uuid primary key default gen_random_uuid(),
  nombre text,
  creado_en timestamptz not null default now()
);

create table productos (
  id uuid primary key default gen_random_uuid(),
  codigo text unique not null,
  modelo_id uuid references modelos(id),
  foto_path text not null,
  tipo text,
  color_principal text,
  atributos jsonb not null default '{}',
  descripcion text,
  precio numeric(10,2),
  embedding vector,
  estado text not null default 'disponible'
    check (estado in ('disponible','consultar','agotado')),
  creado_en timestamptz not null default now(),
  ultima_confirmacion timestamptz not null default now()
);

create table variantes (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null references productos(id) on delete cascade,
  talla text not null,
  cantidad int,
  disponible boolean not null default true,
  unique (producto_id, talla)
);

create table clientes (
  id uuid primary key default gen_random_uuid(),
  wa_id text unique not null,
  nombre text,
  creado_en timestamptz not null default now()
);

create table conversaciones (
  cliente_id uuid primary key references clientes(id),
  bot_pausado_hasta timestamptz,
  ultimo_mensaje_cliente timestamptz
);

create table reservas (
  id uuid primary key default gen_random_uuid(),
  variante_id uuid not null references variantes(id),
  cliente_id uuid not null references clientes(id),
  estado text not null default 'pendiente_pago'
    check (estado in ('pendiente_pago','pago_enviado','confirmada','expirada','cancelada')),
  monto numeric(10,2),
  comprobante_path text,
  origen text not null default 'whatsapp' check (origen in ('whatsapp','live')),
  expira_en timestamptz not null,
  creado_en timestamptz not null default now()
);

create table lives (
  id uuid primary key default gen_random_uuid(),
  inicio timestamptz not null default now(),
  fin timestamptz
);

create table live_items (
  live_id uuid references lives(id) on delete cascade,
  numero int not null,
  producto_id uuid references productos(id),
  primary key (live_id, numero)
);

create table mensajes (
  id bigint generated always as identity primary key,
  cliente_id uuid references clientes(id),
  direccion text not null check (direccion in ('entrante','saliente_bot','saliente_humano')),
  tipo text not null,
  contenido text,
  creado_en timestamptz not null default now()
);

create table config (
  clave text primary key,
  valor jsonb not null
);

create index idx_variantes_producto on variantes(producto_id);
create index idx_reservas_variante on reservas(variante_id);
create index idx_reservas_cliente on reservas(cliente_id);
create index idx_reservas_estado on reservas(estado);
create index idx_mensajes_cliente on mensajes(cliente_id);
create index idx_productos_descripcion_trgm on productos using gin (descripcion gin_trgm_ops);
