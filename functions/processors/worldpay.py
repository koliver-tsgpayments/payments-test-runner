from ._runner import execute

def run_worldpay(event, context=None):
    del event, context
    return execute("worldpay", "https://worldpay.com/en")
