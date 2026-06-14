INSERT INTO auth_user (username, password, role) VALUES
  ('jill.valentine', X'8152B159ECBE74FEED76BD7D4E1965B24F04BE5564FE76A3ED7F7C60BB5D60D0A11CA7316BBF4610DB2E03E834FE19D6', 1),
  ('chris.redfield', X'C489A52B42677E259C29F93128258D535B8CFE5CCAA092EA0CFE395A3615756BA9F95BF0A7FCDE174FB8D8AB8145291B', 1),
  ('barry.burton', X'4B60AB25B88EB7C8C3C847F4D44F2D6142DF71DF072C96FD22C7F2D36A80676E6880786DAEC926CD8FA2E9CE60107880', 2),
  ('rebecca.chambers', X'0F270CAEADD4F648B34411D7A436D53F027E9E89A739B6454BC66E75A53B96075DD9BF92CD825A76CFC0968E6DCF05F6', 2),
  ('wesker.albert', X'A87BA34AFD5DDD0B06BF4E35A8B611FE9E04EACA0B356FD3C3C2A385FC2CD43343D341C26347D4A6EB5A7D3EBC1BD647', 0),
  ('enrico.marini', X'EFAA56CC30042B576BC65E9DE5DE274058CB50C566B26C176858F2D0C2AEBFA06F8A1E9BF24637F3BB8276CD115183E6', 3),
  ('forest.speyer', X'0CCB3338DFCD911DF932C78E0771F2DB03FFB80EA5A33FDAB3DDA0C0D1E3A9CD5AF3BEA108005D78DD8745F6909EA5EF', 3),
  ('richard.aiken', X'ACD0880A56253B4DFB6C2A2338EA6A56DC1E8454458561BC86B37F41BAEDDED56911D3A45D3D248957E9868EE16E7222', 3);

INSERT INTO datamark_source (kind, name, description) VALUES
  ('github', 'comercial', 'Comercial DuckDB schema — ventas, flujos, renta, captación'),
  ('drive',  'operaciones', 'Operaciones — mantenimiento, incidencias, proveedores'),
  ('drive',  'rrhh', 'Recursos Humanos — personal, asistencia, nómina');

INSERT INTO datamark_source_github (source_id, org, repo, release, asset)
SELECT id, 'plaza', 'data-comercial', 'latest', 'comercial.parquet'
FROM datamark_source WHERE name = 'comercial';

INSERT INTO datamark_source_drive (source_id, fpath)
SELECT id, 'Operaciones/datos-operaciones.xlsx' FROM datamark_source WHERE name = 'operaciones'
UNION ALL
SELECT id, 'RRHH/datos-rrhh.xlsx'              FROM datamark_source WHERE name = 'rrhh';

INSERT INTO datamark_view (name, query, source_id) VALUES
  ('💰 Ventas por mes',           'SELECT mes, SUM(venta_total) AS venta_total, SUM(transacciones) AS transacciones FROM comercial.v_ventas GROUP BY mes ORDER BY mes DESC',                                                                                                                                                                                          (SELECT id FROM datamark_source WHERE name = 'comercial')),
  ('📐 Ventas por m²',             'SELECT periodo, tienda, ROUND(SUM(venta_total) / NULLIF(SUM(area_m2), 0), 2) AS venta_m2 FROM comercial.v_venta_m2 GROUP BY periodo, tienda ORDER BY periodo DESC, venta_m2 DESC',                                                                                                                                               (SELECT id FROM datamark_source WHERE name = 'comercial')),
  ('🏷 Ventas por categoría',      'SELECT periodo, categoria, SUM(venta_total) AS venta_total, SUM(venta_anterior) AS venta_anterior, ROUND((SUM(venta_total) - SUM(venta_anterior)) / NULLIF(SUM(venta_anterior), 0) * 100, 2) AS variacion_pct FROM comercial.v_comparativo_ventas_categoria GROUP BY periodo, categoria ORDER BY periodo DESC, venta_total DESC', (SELECT id FROM datamark_source WHERE name = 'comercial')),
  ('🧾 Ticket promedio por categoría', 'SELECT periodo, categoria, ROUND(AVG(ticket_promedio), 2) AS ticket_promedio, SUM(transacciones) AS transacciones FROM comercial.v_ticket_promedio_categoria GROUP BY periodo, categoria ORDER BY periodo DESC, ticket_promedio DESC',                                                                                            (SELECT id FROM datamark_source WHERE name = 'comercial')),
  ('🏢 Renta histórica',           'SELECT periodo, tienda, SUM(renta) AS renta, SUM(mantenimiento) AS mantenimiento, SUM(renta + mantenimiento) AS costo_total FROM comercial.v_historico_renta GROUP BY periodo, tienda ORDER BY periodo DESC, tienda ASC',                                                                                                        (SELECT id FROM datamark_source WHERE name = 'comercial')),
  ('📊 Costo de ocupación',        'SELECT periodo, tienda, SUM(venta_total) AS venta_total, SUM(costo_ocupacion) AS costo_ocupacion, ROUND(SUM(costo_ocupacion) / NULLIF(SUM(venta_total), 0) * 100, 2) AS costo_ocupacion_pct FROM comercial.v_costo_ocupacion GROUP BY periodo, tienda ORDER BY periodo DESC, costo_ocupacion_pct DESC',                          (SELECT id FROM datamark_source WHERE name = 'comercial')),
  ('🚶 Flujo por tienda',          'SELECT periodo, tienda, SUM(visitantes_pasillo) AS visitantes_pasillo, SUM(entradas_tienda) AS entradas_tienda FROM comercial.v_flujos_pasillo_tienda GROUP BY periodo, tienda ORDER BY periodo DESC, entradas_tienda DESC',                                                                                                      (SELECT id FROM datamark_source WHERE name = 'comercial')),
  ('🎯 Captación y conversión',    'SELECT periodo, tienda, ROUND(AVG(tasa_captacion) * 100, 2) AS captacion_pct, ROUND(AVG(tasa_conversion) * 100, 2) AS conversion_pct FROM comercial.v_tasa_captacion_conversion GROUP BY periodo, tienda ORDER BY periodo DESC, conversion_pct DESC',                                                                           (SELECT id FROM datamark_source WHERE name = 'comercial')),
  ('🔁 Conversión por categoría',  'SELECT periodo, categoria, ROUND(AVG(tasa_captacion) * 100, 2) AS captacion_pct, ROUND(AVG(tasa_conversion) * 100, 2) AS conversion_pct, ROUND((AVG(tasa_conversion) - AVG(tasa_conversion_anterior)) * 100, 2) AS variacion_conversion_pp FROM comercial.v_comparativo_captacion_conversion_categoria GROUP BY periodo, categoria ORDER BY periodo DESC, conversion_pct DESC', (SELECT id FROM datamark_source WHERE name = 'comercial'));
