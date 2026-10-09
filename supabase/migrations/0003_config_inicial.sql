insert into config (clave, valor) values
  ('horario', '{"texto": "Por confirmar"}'),
  ('ubicacion_puesto', '{"texto": "Feria Barrio Lindo, Santa Cruz", "puesto": "Por confirmar"}'),
  ('qr_pago_path', '{"path": null}'),
  ('minutos_reserva', '{"minutos": 30}'),
  ('dias_vencimiento_producto', '{"dias": 7}'),
  ('horas_pausa_bot', '{"horas": 2}'),
  ('mensaje_bienvenida', '{"texto": "¡Hola! Bienvenido a Modas Siari 👗 ¿En qué puedo ayudarte? Puedes preguntarme por modelos, tallas o precios."}')
on conflict (clave) do nothing;
