from src.domain.models import Decision


def decide_always_buy(closes, *_ , symbol="2330.TW"):
    return Decision.buy(symbol, 1, "pipeline_test")
