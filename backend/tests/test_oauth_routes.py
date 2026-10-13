import ast
from pathlib import Path


def test_google_authorization_routes_include_provider_id_alias():
    source_path = Path(__file__).parents[1] / "app" / "routers" / "oauth.py"
    module = ast.parse(source_path.read_text(encoding="utf-8"))

    google_authorize = next(
        node
        for node in module.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        and node.name == "google_authorize"
    )
    get_paths = {
        decorator.args[0].value
        for decorator in google_authorize.decorator_list
        if isinstance(decorator, ast.Call)
        and isinstance(decorator.func, ast.Attribute)
        and decorator.func.attr == "get"
        and decorator.args
        and isinstance(decorator.args[0], ast.Constant)
    }

    assert "/google/authorize" in get_paths
    assert "/google_calendar/authorize" in get_paths
