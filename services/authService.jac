import from "@jac/runtime" { jacLogin, jacSignup, jacLogout, jacIsLoggedIn }

async def sign_in(email: str, password: str) -> bool {
    return await jacLogin(email, password);
}

async def sign_up(email: str, password: str) -> str {
    result: dict = {};
    logged_in: bool = False;
    result = await jacSignup(email, password);
    if not result["success"] { return result["error"] as str; }
    logged_in = await jacLogin(email, password);
    if not logged_in { return "Account created, but sign in failed. Please sign in."; }
    return "success";
}

def get_auth_session() -> bool {
    return jacIsLoggedIn();
}

def sign_out() -> None {
    jacLogout();
}
