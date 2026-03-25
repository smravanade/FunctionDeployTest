import logging
import azure.functions as func


def main(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("HTTP trigger function received a request.")

    name = req.params.get("name")
    if not name:
        try:
            req_body = req.get_json()
        except ValueError:
            req_body = {}
        name = req_body.get("name")

    if name:
        return func.HttpResponse(
            f"Hello, {name}! This Azure Function is running in a container.",
            status_code=200,
        )

    return func.HttpResponse(
        "Hello from a containerised Azure Function! "
        "Pass a 'name' query parameter or JSON body to personalise the greeting.",
        status_code=200,
    )
