# Estado de los indicadores anteriormente pendientes

La revisión inicial dejó anotados `Order Blocks`, `Trend Line` y `HLDV` porque en
ese momento no existía una definición operativa completa. Esa nota ya no representa
el estado actual del proyecto:

- `Order Blocks` se calculan en `Market::Indicators::SMC_Structures`, incluyendo
  confirmación, mitigación e invalidación.
- `Trend Lines` y los canales automáticos se calculan con pivotes confirmados y
  registran su ruptura.
- `HLDV` corresponde a las etiquetas estructurales `HH`, `HL`, `LH` y `LL`; ahora
  quedan anotadas en los pivotes externos de `ZigZagDirection`, no sólo dibujadas.

Por tanto, esta lista no mantiene indicadores de cálculo pendientes.
