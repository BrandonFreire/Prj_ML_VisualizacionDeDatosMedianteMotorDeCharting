# Prj_ML_VisualizacionDeDatosMedianteMotorDeCharting

## Pruebas

Las pruebas del motor se ejecutan sin interfaz gráfica ni datos CSV externos:

```bash
prove -I. -lr t
```

La batería verifica agregación OHLCV/replay de `MarketData`, ATR, Liquidity,
SMC y niveles HTF previos. Cada indicador nuevo o corregido debe incorporar
sus casos reproducibles en `t/`.
