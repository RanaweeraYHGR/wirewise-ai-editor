import from "@jac/runtime" { Link, useNavigate }
import from ..services.authService { sign_in }
import from .ui.button { Button }
import from .ui.input { Input }


def:pub Login() -> JsxElement {
    has email: str = "";
    has password: str = "";
    has message: str = "";
    has busy: bool = False;
    nav = useNavigate();

    async def submit(e: SubmitEvent) -> None {
        e.preventDefault();
        if email.strip() == "" or password == "" {
            message = "Enter your email and password to continue.";
            return;
        }
        busy = True;
        ok: bool = False;
        ok = await sign_in(email.strip(), password);
        busy = False;
        if ok { nav("/"); }
        else { message = "Email or password is incorrect."; }
    }

    return <div className="grid min-h-svh bg-muted/40 lg:grid-cols-2">
        <section className="relative hidden flex-col justify-between overflow-hidden bg-primary p-10 text-primary-foreground lg:flex">
            <div className="absolute -right-24 -top-24 size-96 rounded-full bg-primary-foreground/10 blur-3xl" />
            <div className="relative flex items-center gap-3"><div className="flex size-10 items-center justify-center bg-primary-foreground text-primary font-black">L</div><span className="text-xl font-bold tracking-tight">LUMIRA</span></div>
            <div className="relative max-w-lg"><p className="mb-5 text-sm font-medium tracking-widest">ELECTRICAL DESIGN WORKSPACE</p><h1 className="text-balance text-4xl font-semibold leading-tight tracking-tight">Turn your floor plan into a clear electrical design.</h1><p className="mt-5 max-w-md text-primary-foreground/80">Draw rooms, place electrical devices and plan wiring in one focused workspace.</p></div>
            <p className="relative text-sm text-primary-foreground/75">Your designs, ready when you are.</p>
        </section>
        <section className="flex min-h-svh flex-col bg-background px-6 py-8 sm:px-10">
            <div className="flex items-center gap-3 lg:hidden"><div className="flex size-9 items-center justify-center bg-primary text-primary-foreground font-black">L</div><span className="font-bold tracking-tight">LUMIRA</span></div>
            <div className="flex flex-1 items-center justify-center">
                <form onSubmit={submit} className="flex w-full max-w-sm flex-col gap-6">
                    <div><p className="text-sm font-medium text-primary">WELCOME TO LUMIRA</p><h2 className="mt-2 text-3xl font-semibold tracking-tight">Sign in</h2><p className="mt-2 text-sm text-muted-foreground">Access your electrical design workspace.</p></div>
                    <div className="flex flex-col gap-4">
                        <label className="flex flex-col gap-2 text-sm font-medium" htmlFor="login-email">Email<Input id="login-email" type="email" autoComplete="email" required placeholder="you@example.com" value={email} onChange={lambda (e: ChangeEvent) { email = e.target.value; }} /></label>
                        <label className="flex flex-col gap-2 text-sm font-medium" htmlFor="login-password">Password<Input id="login-password" type="password" autoComplete="current-password" required placeholder="Your password" value={password} onChange={lambda (e: ChangeEvent) { password = e.target.value; }} /></label>
                    </div>
                    {message != "" and <p role="alert" className="text-sm text-destructive">{message}</p>}
                    <Button type="submit" disabled={busy} className="h-11 w-full">{"Signing in..." if busy else "Sign in to LUMIRA"}</Button>
                    <p className="text-center text-sm text-muted-foreground">New to LUMIRA? <Link to="/signup" className="font-medium text-foreground underline underline-offset-4">Create an account</Link></p>
                </form>
            </div>
        </section>
    </div>;
}
