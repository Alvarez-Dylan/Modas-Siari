create or replace function siguiente_codigo()
returns text
language sql
as $$
  select 'SIA-' || lpad(nextval('seq_codigo_producto')::text, 4, '0');
$$;

create or replace function registrar_producto(
  p_foto_path text,
  p_atributos jsonb,
  p_descripcion text,
  p_precio numeric,
  p_tallas jsonb,
  p_modelo_id uuid default null
)
returns table (codigo text, producto_id uuid)
language plpgsql
as $$
declare
  v_codigo text;
  v_producto_id uuid;
  v_item jsonb;
begin
  v_codigo := siguiente_codigo();

  insert into productos (codigo, modelo_id, foto_path, tipo, color_principal, atributos, descripcion, precio)
  values (
    v_codigo,
    p_modelo_id,
    p_foto_path,
    p_atributos->>'tipo',
    p_atributos->>'color_principal',
    p_atributos,
    p_descripcion,
    p_precio
  )
  returning id into v_producto_id;

  for v_item in select * from jsonb_array_elements(p_tallas)
  loop
    insert into variantes (producto_id, talla, cantidad)
    values (
      v_producto_id,
      v_item->>'talla',
      case when v_item->>'cantidad' is null then null else (v_item->>'cantidad')::int end
    );
  end loop;

  return query select v_codigo, v_producto_id;
end;
$$;

create or replace function reservar_variante(
  p_codigo text,
  p_talla text,
  p_wa_id text,
  p_origen text default 'whatsapp'
)
returns reservas
language plpgsql
as $$
declare
  v_producto productos;
  v_variante variantes;
  v_cliente_id uuid;
  v_reservadas int;
  v_minutos int;
  v_reserva reservas;
begin
  select * into v_producto from productos where codigo = p_codigo;
  if v_producto is null then
    raise exception 'Producto % no existe', p_codigo;
  end if;

  select * into v_variante
  from variantes
  where producto_id = v_producto.id and talla = p_talla
  for update;

  if v_variante is null then
    raise exception 'Talla % no existe para %', p_talla, p_codigo;
  end if;

  if not v_variante.disponible then
    raise exception 'Talla % de % está agotada', p_talla, p_codigo;
  end if;

  select count(*) into v_reservadas
  from reservas
  where variante_id = v_variante.id
    and estado in ('pendiente_pago', 'pago_enviado');

  if v_variante.cantidad is not null and v_reservadas >= v_variante.cantidad then
    raise exception 'Sin stock disponible para % talla %', p_codigo, p_talla;
  end if;

  insert into clientes (wa_id)
  values (p_wa_id)
  on conflict (wa_id) do update set wa_id = excluded.wa_id
  returning id into v_cliente_id;

  select (valor->>'minutos')::int into v_minutos
  from config where clave = 'minutos_reserva';
  v_minutos := coalesce(v_minutos, 30);

  insert into reservas (variante_id, cliente_id, monto, origen, expira_en)
  values (
    v_variante.id,
    v_cliente_id,
    v_producto.precio,
    p_origen,
    now() + (v_minutos || ' minutes')::interval
  )
  returning * into v_reserva;

  return v_reserva;
end;
$$;

create or replace function registrar_comprobante(
  p_reserva_id uuid,
  p_comprobante_path text,
  p_monto numeric
)
returns reservas
language plpgsql
as $$
declare
  v_reserva reservas;
begin
  update reservas
  set estado = 'pago_enviado',
      comprobante_path = p_comprobante_path,
      monto = coalesce(p_monto, monto)
  where id = p_reserva_id
    and estado = 'pendiente_pago'
  returning * into v_reserva;

  if v_reserva is null then
    raise exception 'Reserva % no está pendiente de pago', p_reserva_id;
  end if;

  return v_reserva;
end;
$$;

create or replace function confirmar_venta(p_reserva_id uuid)
returns reservas
language plpgsql
as $$
declare
  v_reserva reservas;
  v_variante variantes;
begin
  select * into v_reserva from reservas where id = p_reserva_id for update;
  if v_reserva is null then
    raise exception 'Reserva % no existe', p_reserva_id;
  end if;
  if v_reserva.estado not in ('pendiente_pago', 'pago_enviado') then
    raise exception 'Reserva % no se puede confirmar desde estado %', p_reserva_id, v_reserva.estado;
  end if;

  select * into v_variante from variantes where id = v_reserva.variante_id for update;

  if v_variante.cantidad is not null then
    update variantes
    set cantidad = greatest(cantidad - 1, 0),
        disponible = (greatest(cantidad - 1, 0) > 0)
    where id = v_variante.id;
  end if;

  update reservas set estado = 'confirmada' where id = p_reserva_id
  returning * into v_reserva;

  return v_reserva;
end;
$$;

create or replace function registrar_venta_presencial(p_codigo text, p_talla text)
returns variantes
language plpgsql
as $$
declare
  v_producto productos;
  v_variante variantes;
begin
  select * into v_producto from productos where codigo = p_codigo;
  if v_producto is null then
    raise exception 'Producto % no existe', p_codigo;
  end if;

  select * into v_variante
  from variantes
  where producto_id = v_producto.id and talla = p_talla
  for update;

  if v_variante is null then
    raise exception 'Talla % no existe para %', p_talla, p_codigo;
  end if;

  if v_variante.cantidad is not null then
    update variantes
    set cantidad = greatest(cantidad - 1, 0),
        disponible = (greatest(cantidad - 1, 0) > 0)
    where id = v_variante.id
    returning * into v_variante;
  end if;

  return v_variante;
end;
$$;

create or replace function marcar_agotado(p_codigo text, p_talla text default null)
returns void
language plpgsql
as $$
declare
  v_producto_id uuid;
begin
  select id into v_producto_id from productos where codigo = p_codigo;
  if v_producto_id is null then
    raise exception 'Producto % no existe', p_codigo;
  end if;

  if p_talla is null then
    update variantes set disponible = false, cantidad = 0 where producto_id = v_producto_id;
    update productos set estado = 'agotado' where id = v_producto_id;
  else
    update variantes set disponible = false, cantidad = 0
    where producto_id = v_producto_id and talla = p_talla;

    if not exists (select 1 from variantes where producto_id = v_producto_id and disponible) then
      update productos set estado = 'agotado' where id = v_producto_id;
    end if;
  end if;
end;
$$;

create or replace function confirmar_vigentes(p_codigos text[])
returns void
language sql
as $$
  update productos
  set ultima_confirmacion = now(),
      estado = case when estado = 'consultar' then 'disponible' else estado end
  where codigo = any(p_codigos);
$$;

create or replace function expirar_reservas()
returns setof reservas
language sql
as $$
  update reservas
  set estado = 'expirada'
  where estado in ('pendiente_pago', 'pago_enviado')
    and expira_en < now()
  returning *;
$$;

create or replace function vencer_productos()
returns setof productos
language plpgsql
as $$
declare
  v_dias int;
begin
  select (valor->>'dias')::int into v_dias
  from config where clave = 'dias_vencimiento_producto';
  v_dias := coalesce(v_dias, 7);

  return query
  update productos
  set estado = 'consultar'
  where estado = 'disponible'
    and ultima_confirmacion < now() - (v_dias || ' days')::interval
  returning *;
end;
$$;

create or replace function buscar_productos(
  p_tipo text default null,
  p_color text default null,
  p_talla text default null,
  p_texto text default null
)
returns table (
  codigo text,
  foto_path text,
  tipo text,
  color_principal text,
  descripcion text,
  precio numeric,
  estado text,
  talla text,
  cantidad int,
  disponible boolean
)
language sql
stable
as $$
  select
    p.codigo,
    p.foto_path,
    p.tipo,
    p.color_principal,
    p.descripcion,
    p.precio,
    p.estado,
    v.talla,
    v.cantidad,
    v.disponible
  from productos p
  join variantes v on v.producto_id = p.id
  where p.estado in ('disponible', 'consultar')
    and v.disponible
    and (p_tipo is null or p.tipo ilike p_tipo)
    and (p_color is null or p.color_principal ilike p_color)
    and (p_talla is null or v.talla = p_talla)
    and (
      p_texto is null
      or p.descripcion ilike '%' || p_texto || '%'
      or similarity(coalesce(p.descripcion, ''), p_texto) > 0.2
    )
  order by
    case when p_texto is null then 0 else similarity(coalesce(p.descripcion, ''), p_texto) end desc,
    p.creado_en desc;
$$;

create or replace function buscar_por_imagen(p_embedding vector, p_limite int default 5)
returns table (
  codigo text,
  foto_path text,
  descripcion text,
  precio numeric,
  estado text,
  distancia float
)
language sql
stable
as $$
  select
    p.codigo,
    p.foto_path,
    p.descripcion,
    p.precio,
    p.estado,
    p.embedding <=> p_embedding as distancia
  from productos p
  where p.embedding is not null
    and p.estado in ('disponible', 'consultar')
  order by p.embedding <=> p_embedding
  limit p_limite;
$$;
