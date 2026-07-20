# Prj_ML_VisualizacionDeDatosMedianteMotorDeCharting

## Pruebas

Las pruebas del motor se ejecutan sin interfaz gráfica ni datos CSV externos:

```bash
prove -I. -lr t
```

La batería verifica agregación OHLCV/replay de `MarketData`, ATR, Liquidity,
SMC, niveles HTF, régimen, señales y backtesting. Cada indicador nuevo o
corregido debe incorporar sus casos reproducibles en `t/`.

## Evaluación de señales

`Market::Indicators::Strategy_Builder` expone `run_backtest()`. Una señal
confirmada en la vela `i` entra únicamente en la apertura de `i + 1`; no se
puede usar el máximo o mínimo de la vela que la originó.

```perl
my $result = $strategy->run_backtest(
    initial_capital   => 10_000,
    risk_per_trade    => 0.01,
    stop_atr_multiple => 1.5,
    reward_risk       => 2,
    commission_bps    => 1,
    slippage_bps      => 1,
);
```

El resultado incluye operaciones, curva de equity, drawdown y señales
descartadas. Si una vela toca SL y TP, el modo `stop_first` es conservador por
defecto; `intrabar_priority => 'target_first'` sirve solo para analizar la
sensibilidad de ese supuesto.

## Régimen ML y pivotes omitidos

`Market::ML::RegimePipeline` clasifica el contexto de forma no supervisada.
Hay que indicar el último índice de entrenamiento: la salida solo contiene
predicciones posteriores a él y no es una señal de compra/venta.

```perl
my $ml = Market::ML::RegimePipeline->new(feature_window => 20);
my $regimes = $ml->compute(
    candles         => $candles,
    atr_series      => $strategy->get_atr(),
    train_end_index => 3_000,
);
```

`Market::Indicators::PivotMissedReversal` ofrece pivotes regulares,
reversiones omitidas, su nivel activo y un extremo provisional. Los eventos
se publican al confirmarse, nunca en la vela extrema con información futura.
