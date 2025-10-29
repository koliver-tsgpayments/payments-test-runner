from ._runner import execute

def run_tsgpayments(event, context=None):
    del event, context  # background signature compatibility
    return execute("tsgpayments", "https://tsgpayments.com/")
