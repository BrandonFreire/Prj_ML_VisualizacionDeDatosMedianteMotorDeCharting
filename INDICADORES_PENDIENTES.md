# Estado de la comparación técnica

Revisión actualizada contra `Francis1918/ML_Project`, usando `claude-import`
como rama de referencia. Se excluyen deliberadamente la API y la aplicación web.

## Implementado y comprobado

- SMC: pivotes internos/externos, BOS, CHoCH, MSS, FVG, Order Blocks,
  Premium/Discount y Major High/Low.
- Liquidez: niveles, EQL/EQH y clasificación SWEEP/GRAB/RUN.
- Strategy Builder: SuperTrend, HalfTrend, Range Filter, Supply/Demand,
  señales, backtest y canales de tendencia.
- Volume Profile: POC, VAH y VAL en rangos manuales; el motor también admite
  sesión, BOS/CHoCH y contingencia.
- Anchored VWAP: anclajes configurados, desviaciones 1x/2x/3x y anclaje
  automático al último missed pivot confirmado.
- ZigZag/HLDV: dirección interna/externa y clasificación HH/HL/LH/LL.
- Pivot Missed Reversal: pivotes regulares, fantasmas confirmados, niveles,
  segmentos opcionales y fantasma provisional. En `2026_03.csv` coincide con
  la referencia: 149 pivotes regulares y 24 missed pivots confirmados.
- Los cálculos anteriores respetan el cursor de Replay en las pruebas actuales.

## Diferencias reales todavía pendientes

### Prioridad alta

1. **Paridad del modelo ML.** El extractor local usa cinco variables de
   precio/volumen. La referencia usa catorce e incorpora distancia y contacto
   con liquidez, BOS, CHoCH y contexto FVG/Order Block.
2. **GMM con covarianza completa.** El GMM local usa covarianza diagonal. La
   referencia modela también la correlación entre variables mediante matrices
   de covarianza completas y Cholesky estable.

### Prioridad media

3. **Funciones adicionales de Strategy Builder.** Faltan niveles directos de
   soporte/resistencia, niveles diarios de cuerpo/mecha y el resumen de
   confirmaciones del dashboard/ML de la referencia.
4. **Modos operativos de Volume Profile.** Los modos de sesión, BOS/CHoCH y
   contingencia existen en el motor local, pero la interfaz sólo ofrece el
   anclaje manual. También falta el modo automático anclado a missed pivots.
5. **Integración de cálculos existentes.** `MTFLevels`, `InternalZigZag`,
   `ZonaInterna` y el pipeline ML tienen cálculo y pruebas, pero no todos están
   conectados a un overlay/opción visible en la aplicación de escritorio.

### Prioridad baja u opcional

6. **t-SNE.** La referencia incluye un auditor visual t-SNE. Sirve para
   inspeccionar clusters, no para generar por sí mismo señales de trading.
7. **Módulos auxiliares separados.** La referencia separa `StandardScaler` y
   la detección de dependencias opcionales (`Capability`). En el proyecto local
   parte de esa lógica está integrada en otros módulos, pero no existe el mismo
   contrato reutilizable.

## Diferencias deliberadas

- El ZigZag local prioriza pivotes confirmados y comportamiento causal. La
  variante activa/repainting de la referencia no se considera un reemplazo
  seguro para Replay o backtest.
- El AVWAP automático local sólo acepta missed pivots confirmados. La referencia
  puede anclarlo al fantasma provisional; hacerlo por defecto movería el ancla
  mientras llega nueva información.
- Un Volume Profile en modo manual produce cero perfiles antes de seleccionar
  un rango; ese estado no es un error de cálculo.
