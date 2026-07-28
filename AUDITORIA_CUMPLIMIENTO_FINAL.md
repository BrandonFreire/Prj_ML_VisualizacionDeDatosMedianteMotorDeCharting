# Auditoría de cumplimiento — modelo predictivo Ghosts_in_swings

Fecha de auditoría: 2026-07-27  
Documento normativo: `Indicaciones-Proyecto-parte-final_v1.0.txt`, versión 1.0  
Datos oficiales: `2026_Abril-Junio.csv` y `2026_07_24.csv`

## Dictamen ejecutivo

El estado inicial **no cumplía** los requisitos centrales:

- `ml/train.py` entrenaba un Random Forest, no una LSTM.
- El artefacto alterno `artifacts/models/trained_model.pt` declaraba una GRU.
- El extractor antiguo sólo generaba un subconjunto de niveles, no calculaba
  la matriz 1m/10m/1h y confundía el objetivo con retocar un precio fijo.
- El scaler se ajustaba antes de separar validación, contaminando esa métrica.
- `ml/evaluate.py` usaba `os` sin importarlo y fallaba al iniciar.
- `ml/run_all.sh` apuntaba por defecto a CSV de marzo/julio que ya no existen.
- La interfaz Tk cargaba el artefacto Random Forest y permitía entrenar con el
  CSV visualizado, en vez de imponer abril-junio.

Después del refactor, el flujo técnico solicitado está implementado y fue
ejecutado de extremo a extremo. El archivo oficial `Ghosts_in_swings.txt` ya
fue incorporado y permitió cerrar la homologación. La revisión encontró cinco
desviaciones materiales:

1. El valor oficial es `Pivot Length = 50`; el extractor usaba 20.
2. El Pine recibido creaba dos etiquetas `1` para el mismo cursor.
3. La condición `barstate.isconfirmed` no comprobaba que el fantasma hubiera
   cambiado; así etiquetaba cada vela y convertía Y en un objetivo casi
   determinista.
4. Las bandas sumaban `(precio - VWAP_actual)^2` mientras la media cambiaba,
   por lo que la desviación estándar ponderada quedaba subestimada.
5. `math.max(high[length], max)` y su equivalente mínimo recibían `na` durante
   el warm-up. Pine propaga ese `na`, contaminando el estado inicial de
   extremos; ahora sólo se actualiza cuando existe la vela retardada y usa
   inicialización explícita.

El Pine y la traducción Perl ahora dejan una sola etiqueta cuando cambia el
ancla o aparece un extremo estrictamente nuevo. Las tres rutas AVWAP del Pine
usan ahora Welford ponderado, igual que el motor Perl. La LSTM cumple la
arquitectura, pero su capacidad predictiva sigue siendo débil: el R² externo
sólo es ligeramente positivo en 10 y 15 minutos.

La integración visual tampoco era idéntica: consumía el último missed pivot,
pero no construía las dos curvas dinámicas de la fuente. Se añadieron
`Swing VWAP` desde el último pivote regular confirmado y `Ghost VWAP` desde el
fantasma vivo; el AVWAP manual existente se mantiene.

## Integridad de los datos

| Dataset | Periodo observado | Velas | Duplicados | OHLCV inválido |
|---|---:|---:|---:|---:|
| `2026_Abril-Junio.csv` | 2026-04-01 a 2026-06-30 | 88 736 | 0 | 0 |
| `2026_07_24.csv` | 2026-07-01 a 2026-07-24 15:59 | 24 179 | 0 | 0 |

El extractor produjo:

| Tabla | Eventos completos | Columnas | Periodo |
|---|---:|---:|---|
| `ml/features_train.csv` | 8 012 | 76 | abril-junio |
| `ml/features_test.csv` | 2 440 | 76 | 1-24 julio |

Las 76 columnas se dividen en 8 metadatos, 64 features y 4 objetivos.

## 1. Extractor de características

### Replay y Ghosts_in_swings

Estado: **cumple; homologado con la fuente adjunta y probado bar a bar**.

`Market::ML::GhostFeatureExtractor` es un módulo analítico independiente de
Tk. Consume el Replay implementado por
`Market::Indicators::PivotMissedReversal`, con el estado inicial y la prioridad
PH/PL de la fuente. Publica:

- `appearance`: aparece el primer fantasma o cambia el ancla confirmada;
- `move`: el fantasma se desplaza a un nuevo extremo; este movimiento es un
  rastro futuro.

Una vela que iguala el extremo puede mover visualmente el icono (la búsqueda
del Pine prioriza la vela más reciente), pero no sale del rango y no genera
otro `1`. La prueba golden cubre aparición, cambio de ancla, movimiento
estricto y empate.

Cada evento conserva `event_index`, `ghost_index`, tipo, precio y timestamp.
Nunca se acepta un `ghost_index` posterior al evento. La prueba de invariancia
confirma que extraer un prefijo Replay genera las mismas features y targets que
extraer el historial completo para esos mismos eventos.

La predicción se emite al cierre de la vela de aparición/reubicación. Los
niveles estructurales usan únicamente velas cerradas anteriores al evento:

- en 1m se excluye la vela del evento;
- en 10m y 1h sólo se usan buckets macro ya cerrados;
- ATR, volumen y EMA(9) corresponden a la vela 1m del evento, conocida al
  emitir la predicción.

### Distancias y once grupos

La referencia corregida es el promedio de la vela donde está el fantasma:
`ghost_hlc3 = (high[ghost_index] + low[ghost_index] +
close[ghost_index]) / 3`. Una distancia se codifica con signo:

`distancia_pips = (nivel - ghost_hlc3) / pip_size`

Los espesores se expresan como `abs(top - bottom) / pip_size`. El valor PIP
predeterminado es 0.25 para NQ y puede cambiarse con `--pip-size`.

| # | Grupo | Implementación y columnas | Causalidad |
|---:|---|---|---|
| 1 | Order Block | distancia al centro y espesor en 1m/10m/1h | sólo OB confirmado y no mitigado al cursor |
| 2 | FVG | distancia al centro y espesor en 1m/10m/1h | `formed_at <= cursor < mitigated_at` |
| 3 | Fibonacci | nivel más cercano de 0.236/0.382/0.5/0.618/0.786 en 1m/10m/1h | últimos dos pivotes externos alternos ya confirmados |
| 4 | Anchored VWAP | VWAP, banda 1 y banda 2 en 1m/10m/1h | ancla en el penúltimo pivote externo; sumas sólo hasta el cursor |
| 5 | Perfil de volumen | POC, VAH y VAL en 1m/10m/1h | perfil fijo del último impulso externo consolidado |
| 6 | S/R | distancia al nivel más cercano de 4h, diario y semanal | máximo/mínimo del periodo cerrado anterior |
| 7 | BOS/CHoCH | distancia al nivel etiquetado en 1m/10m/1h | evento confirmado dentro del contexto reciente |
| 8 | EQH/EQL | distancia al nivel de igualdad en 1m/10m/1h | `eq_confirmed_at` alcanzado y nivel aún no barrido |
| 9 | Sweep/Grab/Run | distancia al nivel clasificado en 1m/10m/1h | sólo después de `resolved_at` |
| 10 | Supply/Demand | distancia y espesor en 1m/10m/1h | OB validado con percentil de volumen calculado sólo con pasado |
| 11 | Canal/Trendline | distancia al borde y ancho en 1m/10m/1h | tres mínimos HL o LL lineales, duración ≥2h, contención ≥85 %, ATR/precio bajo y ruptura posterior filtrada por cursor |

También se incluyen obligatoriamente `atr_1m`, `volume_1m` y
`volume_ema9_1m`.

La disponibilidad real es alta para casi todos los grupos. Los niveles
intrínsecamente escasos se guardan vacíos y el scaler aprende una imputación
exclusivamente con entrenamiento. Ejemplos en train: EQH/EQL 1h 7.1 % y canal
1m/10m/1h 25.4 %/31.9 %/32.6 %.

### Objetivos futuros

Estado: **cumple**.

`Y_3m`, `Y_5m`, `Y_10m` y `Y_15m` cuentan reubicaciones posteriores en el
intervalo `(t, t + N minutos]`. No se cuentan barras ni retouches de un nivel
fijo. La comparación usa timestamps, por lo que un cierre de mercado no se
convierte artificialmente en “N barras futuras”.

Las cuatro etiquetas son acumulativas y no se observaron violaciones de
monotonicidad en train o test. Los eventos de los últimos 15 minutos se omiten
al construir datasets etiquetados; `--include-incomplete` los conserva con Y
vacío para predicción en vivo.

### Rendimiento

La primera versión auditada recorría todas las zonas históricas por cada
evento. Se sustituyó por streams incrementales por temporalidad:

- cada OB/FVG/EQ/canal entra cuando queda disponible;
- expira al mitigarse, barrerse o romperse;
- BOS/CHoCH y Sweep/Grab/Run mantienen una ventana causal acotada;
- ATR usa sumas prefijas y VWAP usa acumulados ponderados.

La extracción de control de 18 658 velas bajó de 26.2 s a 4.4 s, con las mismas
reglas. El pipeline oficial completo terminó correctamente.

## 2. Pipeline LSTM

### Esquema de entrada

Estado: **cumple**.

- 62 variables numéricas.
- 2 variables categóricas (`ghost_type`, `relocation`) convertidas a cuatro
  indicadores one-hot.
- Tensor final: 66 features.
- Secuencia: 16 eventos.

Se excluyen explícitamente de X:

`event_id`, `event_timestamp`, `event_date`, `event_hour`, `event_minute`,
`event_index`, `ghost_index`, `complete` y los cuatro targets.

Los metadatos sólo ordenan las secuencias y permiten presentar resultados.

### Normalización y persistencia

Estado: **cumple**.

`Preprocessor` aprende en train:

- mediana para valores estructurales ausentes;
- media y desviación estándar para cada variable numérica;
- esquema y orden exacto de features.

Durante la selección temporal, el scaler se ajusta sólo con el 80 % inicial.
Se purgan 15 minutos antes del inicio de validación para que ningún target de
train atraviese la frontera. Elegida la época, el modelo final y su scaler se
reajustan con todo abril-junio. Julio ejecuta exclusivamente
`Preprocessor.load(...).transform(...)`; no hay `fit` en evaluación.

Artefacto persistido:

- `ml/scaler_params_lstm.npz`
- SHA-256 observado:
  `a5fec5af5fe5aad16b4811e532eeb79eeeea6c82872836aeb8721ba6a664813a`

### Arquitectura y pesos

Estado: **cumple**.

Arquitectura efectiva:

- una capa LSTM;
- input 66;
- estado oculto 32;
- cabeza densa de 4 salidas simultáneas;
- ninguna capa CNN/Conv;
- salida restringida a conteos no negativos, límites 3/5/10/15 y orden
  monótono entre horizontes.

El modelo final se entrenó con las 8 012 filas completas de abril-junio. La
selección temporal eligió la época 1; entrenar más reducía el error de train
pero empeoraba validación, señal clara de sobreajuste.

Artefacto persistido:

- `ml/model_fantasmas_lstm.npz`
- matrices LSTM: `W(98,128)`, cabeza `Wy(32,4)`
- SHA-256 observado:
  `426274b15a1e4b657890946a139e19f6b0f250cf2ea1c2cb6688b6fd6d5dd6e7`

### Evaluación externa de julio

Estado operativo: **cumple**. Calidad predictiva: **insuficiente para uso de
trading sin más investigación**.

| Target | N | MAE | RMSE | R² | Exacta | ±1 |
|---|---:|---:|---:|---:|---:|---:|
| Y_3m | 2 425 | 0.888 | 1.046 | -0.007 | 28.1 % | 86.1 % |
| Y_5m | 2 425 | 1.242 | 1.478 | -0.035 | 20.6 % | 64.5 % |
| Y_10m | 2 425 | 1.830 | 2.202 | 0.015 | 14.3 % | 43.7 % |
| Y_15m | 2 425 | 2.330 | 2.812 | 0.006 | 12.2 % | 35.2 % |

El resultado apenas supera una predicción constante basada en la media en
10m/15m y no la supera en 3m/5m. Esto no invalida la conformidad
arquitectónica, pero sí impide presentar el modelo como una ventaja predictiva
comprobada.

## 3. Arquitectura, rendimiento y look-ahead

Estado: **cumple en los caminos auditados**.

- `Market::ML::GhostFeatureExtractor` no importa Tk, Canvas ni overlays.
- `ml/extract_features.pl` sólo orquesta I/O y el motor analítico.
- Los overlays siguen leyendo resultados; no calculan features de ML.
- El indicador analítico expone anclas/rastros y el AVWAP analítico produce
  las curvas regular y fantasma; Tk se limita a renderizarlas.
- Los niveles estructurales se consultan con cursores anteriores al evento.
- Los ciclos de vida calculados en batch se filtran por `confirmed_at`,
  `resolved_at`, `mitigated_at`, `end_index` o `break_at`.
- La tabla Y nunca forma parte de X.
- La separación train/validación es temporal y tiene purga de 15 minutos.
- El test de julio no participa en selección, escalado ni entrenamiento.
- La interfaz Tk ahora apunta al modelo LSTM y el botón de entrenamiento
  ejecuta el pipeline oficial abril-junio/julio.
- Al arrancar, la interfaz carga por defecto `2026_07_24.csv`, no el dataset de
  entrenamiento. Abril-junio sólo se abre dentro del proceso explícito
  **Entrenar Modelo**; predecir únicamente recarga modelo/scaler y transforma
  las features del CSV visualizado.

Durante la auditoría aparecieron tres regresiones preexistentes de overlays:
un mock sin `find`, orden duplicado al bajar zonas y fallback Fibonacci. Se
centralizó el `lower('smc_zone', 'candles')` y se prioriza Fibonacci externo
con fallback interno durante warm-up. La batería volvió a verde.

## Evidencia reproducible

Comandos ejecutados:

```bash
bash ml/run_all.sh
prove -I. -lr t
python3 -m unittest ml/test_lstm_core.py
python3 -m py_compile ml/lstm_core.py ml/train.py ml/evaluate.py ml/predict.py
perl -I. -c market.pl
```

Resultados:

- Perl: 27 archivos, 538 pruebas, todas exitosas.
- Python: 3 pruebas del pipeline LSTM, todas exitosas.
- Sintaxis de los cuatro módulos Python: correcta.
- Sintaxis de `market.pl`: correcta.
- Prueba explícita de invariancia prefijo Replay/historial completo: exitosa.
- Persistencia y recarga exacta de scaler y pesos: exitosa.

## Riesgos y acciones pendientes

1. **Compilar el Pine corregido en TradingView.** El workspace no incluye un
   compilador/runtime Pine; la traducción Perl sí tiene fixture golden y Replay,
   pero la validación visual final del archivo `.txt` debe hacerse en Pine
   Editor v6.
2. **No usar aún las predicciones para decisiones reales.** La mejora de
   10m/15m es marginal y 3m/5m siguen por debajo del baseline de media.
3. **Revisar definición/rareza de EQH/EQL 1h.** La cobertura es muy baja y
   puede aportar poco al modelo.
4. **Comparar contra baselines.** Media por horizonte, Poisson/Negative
   Binomial y un MLP pequeño permitirán demostrar si la secuencia LSTM añade
   información.
5. **Calibrar por instrumento.** `pip_size=0.25` es correcto para NQ; debe
   parametrizarse al cambiar de mercado.
6. **Mantener artefactos legacy fuera del flujo oficial.** Los `.joblib` y la
   GRU se preservaron para trazabilidad y no deben presentarse como el modelo
   final.
