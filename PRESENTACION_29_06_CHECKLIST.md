# Checklist primera presentacion - 29/06

## Estado para la demo

El proyecto carga datos OHLCV desde `2026_03.csv`, construye temporalidades desde la serie base de 1 minuto, calcula ATR, SMC Structures y Liquidity, y renderiza velas, escalas, panel ATR y overlays sobre Tk Canvas.

## Puntos implementados para la primera presentacion

- Motor base con multiples temporalidades: `1m`, `5m`, `15m`, `1h`, `2h`, `4h`, `D` y `W`.
- Agregacion OHLCV por bucket:
  - `open`: primera vela del bucket.
  - `high`: maximo del bucket.
  - `low`: minimo del bucket.
  - `close`: ultima vela del bucket.
  - `volume`: suma del bucket.
  - `time`: inicio del bucket.
- Sistema Replay minimo:
  - `replay_mode` activa la barrera temporal.
  - `replay_cursor` limita la ultima vela visible.
  - ATR, SMC y Liquidity se recomputan contra datos truncados hasta `replay_cursor`.
  - Step backward, step forward, play/pause, fast forward y salida de Replay.
  - El render pasa `current_bar` a los overlays para evitar eventos futuros.
- Arquitectura base de overlays:
  - `ChartEngine` registra overlays con `add_overlay`.
  - Cada overlay borra solo su tag antes de redibujar.
- SMC Structures:
  - Swing highs/lows, BOS, CHoCH y FVG.
  - BOS/CHoCH se ubican entre swing original y ruptura.
  - FVG se recorta por rango visible, `current_bar`, mitigacion y edad maxima visual.
- Liquidity:
  - Deteccion de BSL/SSL y EQH/EQL.
  - Maquina de estados con SWEEP, GRAB y RUN.
  - Lineas BSL/SSL recortadas al rango real visible y a `swept_at`.
  - Etiquetas de nivel `BSL`, `SSL`, `EQH` y `EQL`.
  - Etiquetas finales `SWEEP ↑`, `SWEEP ↓`, `LQ GRAB` y `LQ RUN`.

## Archivos principales

- `market.pl`: carga CSV, inicializa Tk, crea indicadores, overlays, botones de temporalidad y controles Replay.
- `Market/MarketData.pm`: almacenamiento de velas y construccion de temporalidades.
- `Market/ChartEngine.pm`: render principal, escalas, pan/zoom, Replay y recomputo por timeframe.
- `Market/Panels/PricePanel.pm`: velas, grid, eje de tiempo, crosshair y precio visible.
- `Market/Panels/Scales.pm`: conversion indice/precio a coordenadas de canvas.
- `Market/IndicatorManager.pm`: registro, reset, computo y slicing de indicadores.
- `Market/Indicators/SMC_Structures.pm`: calculo de swings, BOS, CHoCH y FVG.
- `Market/Indicators/Liquidity.pm`: niveles BSL/SSL y maquina de estados.
- `Market/Overlays/SMC_Structures.pm`: render de BOS, CHoCH, FVG y ZAR.
- `Market/Overlays/Liquidity.pm`: render de BSL/SSL y etiquetas de resolucion.

## Como ejecutar

```powershell
perl market.pl
```

Si se usa el Perl portable del repositorio:

```powershell
.\local\strawberry-perl\perl\bin\perl.exe market.pl
```

## Comandos de validacion

```powershell
perl -c market.pl
perl -c Market/MarketData.pm
perl -c Market/ChartEngine.pm
perl -c Market/IndicatorManager.pm
perl -c Market/Indicators/SMC_Structures.pm
perl -c Market/Indicators/Liquidity.pm
perl -c Market/Overlays/SMC_Structures.pm
perl -c Market/Overlays/Liquidity.pm
```

Con Perl portable:

```powershell
.\local\strawberry-perl\perl\bin\perl.exe -c market.pl
.\local\strawberry-perl\perl\bin\perl.exe -c Market/MarketData.pm
.\local\strawberry-perl\perl\bin\perl.exe -c Market/ChartEngine.pm
.\local\strawberry-perl\perl\bin\perl.exe -c Market/IndicatorManager.pm
.\local\strawberry-perl\perl\bin\perl.exe -c Market/Indicators/SMC_Structures.pm
.\local\strawberry-perl\perl\bin\perl.exe -c Market/Indicators/Liquidity.pm
.\local\strawberry-perl\perl\bin\perl.exe -c Market/Overlays/SMC_Structures.pm
.\local\strawberry-perl\perl\bin\perl.exe -c Market/Overlays/Liquidity.pm
```

## Validacion visual esperada

- La consola muestra conteos para `1m`, `5m`, `15m`, `1h`, `2h`, `4h`, `D` y `W`.
- La ventana Tk abre y muestra velas.
- Los botones de temporalidad cambian el timeframe y redibujan velas, ATR, SMC y Liquidity.
- Replay no muestra velas futuras.
- ATR, SMC y Liquidity se recalculan solo hasta el cursor de Replay.
- Step backward/forward mueve la barrera temporal.
- Play/Pause y Fast Forward avanzan el cursor.
- Exit Replay vuelve al historico completo.
- FVG no se extiende al infinito.
- FVG mitigado termina en la vela de mitigacion.
- BSL/SSL no se extienden al infinito y terminan en `swept_at` si corresponde.
- Las etiquetas de liquidez aparecen solo si el evento resuelto esta visible.

## Cobertura del PDF para primera presentacion

- Temporalidades: cubierto en el motor base y UI.
- Replay: cubierto como version minima funcional sin velas futuras.
- Overlays: cubierto mediante arquitectura de overlays registrados en `ChartEngine`.
- SMC: cubierto con Swing Points, BOS, CHoCH y FVG.
- FVG con desvanecimiento temporal: cubierto con edad visual maxima y `stipple`.
- Liquidity: cubierto con BSL/SSL, EQH/EQL y maquina de estados SWEEP/GRAB/RUN.

## Pendiente para segunda presentacion

- Strategy Builder completo.
- Perfil de Volumen avanzado.
- Anchored VWAP multipivot.
- Analisis multi-temporal mas avanzado, si se requiere mas que cambio de timeframe y recomputo por temporalidad.
- Validaciones visuales mas profundas y escenarios de demo grabados.
