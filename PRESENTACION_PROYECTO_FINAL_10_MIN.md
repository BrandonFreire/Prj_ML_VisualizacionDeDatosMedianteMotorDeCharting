# Presentación final — extractor causal y LSTM de Ghosts_in_swings

Duración objetivo: 9:30 minutos + 0:30 de margen.

## 1. Problema y datos — 0:00 a 0:45

- Objetivo: predecir cuántas reubicaciones/rastros futuros tendrá el fantasma
  en 3, 5, 10 y 15 minutos.
- Train: abril-junio, 88 736 velas 1m.
- Test externo: 1-24 julio, 24 179 velas 1m.
- Separación temporal estricta; julio nunca ajusta modelo ni scaler.

Visual sugerido: línea de tiempo abril → junio | julio.

## 2. Replay y definición del evento — 0:45 a 1:45

- El pivote sólo existe después de su confirmación.
- `appearance`: aparece el fantasma provisional.
- `move`: un nuevo extremo reubica el fantasma y deja un rastro.
- Parámetro homologado con la fuente: `Pivot Length = 50`.
- El Pine recibido duplicaba `1` y lo imprimía sin comprobar movimiento; se
  corrigió para dejar un solo rastro por extremo estrictamente nuevo.
- Las bandas AVWAP se corrigieron con varianza ponderada estable (Welford).
- Features en el cierre del evento; estructura sólo de velas anteriores.
- Targets: cantidad de eventos `move/appearance` en `(t,t+N]`.

Demo corta: mostrar 5 filas consecutivas de `ml/features_test.csv`.

## 3. Arquitectura del extractor — 1:45 a 2:30

- Motor puro `Market::ML::GhostFeatureExtractor`.
- Sin Tk, Canvas ni código de renderizado.
- Buckets cerrados de 1m, 10m y 1h.
- Índices incrementales para OB/FVG/EQ/canales y sumas prefijas para ATR/VWAP.

Visual sugerido:

`OHLCV 1m → Replay → contextos 1/10/60 → CSV de 76 columnas`

## 4. Features — 2:30 a 4:15

Mostrar una tabla compacta:

1. OB: distancia + ancho.
2. FVG: distancia + ancho.
3. Fibonacci externo.
4. AVWAP del penúltimo pivote + bandas.
5. POC/VAH/VAL.
6. S/R 4h, diario, semanal.
7. BOS/CHoCH.
8. EQH/EQL.
9. Sweep/Grab/Run.
10. Supply/Demand validado por volumen.
11. Canal de tres mínimos, ≥2h y ATR bajo.

Todos los precios se expresan respecto al HLC3 de la vela donde está el
fantasma (`ghost_index`) y en PIP. Se agregan ATR 1m, volumen 1m y EMA(9) del
volumen.

En la interfaz, `Swing VWAP` parte del último pivote regular y `Ghost VWAP` de
la ubicación causal del fantasma; el anclaje manual previo se conserva.

## 5. Prevención de fuga — 4:15 a 5:15

- Fecha/hora/minuto/timestamp/índices se conservan como metadatos y se excluyen
  de X.
- Los cuatro targets se excluyen de X.
- Validación temporal 80/20 con purga de 15 minutos.
- Scaler de selección ajustado sólo con el tramo train.
- Modelo final y scaler ajustados con todo abril-junio.
- En julio sólo se recargan pesos y se ejecuta `transform`.
- Prueba automática: un prefijo Replay coincide con el historial completo.

## 6. Modelo LSTM — 5:15 a 6:15

- Secuencias de 16 eventos.
- 66 entradas: 62 numéricas + 4 one-hot.
- LSTM con estado oculto 32.
- Capa densa con cuatro salidas simultáneas.
- Sin CNN ni GRU.
- Persistencia en `model_fantasmas_lstm.npz` y
  `scaler_params_lstm.npz`.

## 7. Resultados — 6:15 a 7:30

| Ventana | MAE | RMSE | R² | Exacta | ±1 |
|---|---:|---:|---:|---:|---:|
| 3m | 0.888 | 1.046 | -0.007 | 28.1 % | 86.1 % |
| 5m | 1.242 | 1.478 | -0.035 | 20.6 % | 64.5 % |
| 10m | 1.830 | 2.202 | 0.015 | 14.3 % | 43.7 % |
| 15m | 2.330 | 2.812 | 0.006 | 12.2 % | 35.2 % |

Mensaje oral recomendado: “El pipeline funciona y la evaluación es honesta.
El R² es ligeramente positivo en 10 y 15 minutos, pero negativo en 3 y 5; la
ventaja todavía es demasiado débil para uso real. No confundimos conformidad
técnica con calidad predictiva.”

## 8. Demo final — 7:30 a 9:00

```bash
python3 ml/predict.py ml/features_test.csv --last 10
```

Mostrar:

- carga de la LSTM;
- carga del scaler;
- fecha/tipo de evento sólo para presentación;
- cuatro predicciones no negativas y monótonas;
- CSV de salida.

## 9. Cierre y trabajo futuro — 9:00 a 9:30

- Comparar LSTM con baseline de media y modelos de conteo.
- Investigar escasez de EQH/EQL 1h.
- Ajustar hiperparámetros sin tocar julio.
