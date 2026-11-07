import from "@jac/runtime" { Link, useNavigate }
import from ..services.authService { sign_up }
import from .ui.button { Button }
import from .ui.input { Input }


def:pub Signup() -> JsxElement {
    has email: str = "";
    has password: str = "";
    has message: str = "";
    has busy: bool = False;
    nav = useNavigate();

    async def submit(e: SubmitEvent) -> None {
        e.preventDefault();
        if email.strip() == "" or password == "" {
            message = "Enter an email and password to create your account.";
            return;
        }
        busy = True;
        result: str = "";
        result = await sign_up(email.strip(), password);
        busy = False;
        if result == "success" { nav("/"); }
        else { message = result; }
    }

    return <div className="grid min-h-svh bg-muted/40 lg:grid-cols-2">
        <section className="relative hidden flex-col justify-between overflow-hidden bg-primary p-10 text-primary-foreground lg:flex">
            <div className="absolute -right-24 -top-24 size-96 rounded-full bg-primary-foreground/10 blur-3xl" />
            <div className="relative flex items-center gap-3"><div className="flex size-10 items-center justify-center bg-primary-foreground text-primary font-black">L</div><span className="text-xl font-bold tracking-tight">LUMIRA</span></div>
            <div className="relative max-w-lg"><p className="mb-5 text-sm font-medium tracking-widest">YOUR ELECTRICAL DESIGN WORKSPACE</p><h1 className="text-balance text-4xl font-semibold leading-tight tracking-tight">Plan with confidence, from first room to final circuit.</h1><p className="mt-5 max-w-md text-primary-foreground/80">Create an account to start designing and keep your workspace ready for your next session.</p></div>
            <p className="relative text-sm text-primary-foreground/75">A clearer path from plan to wiring.</p>
        </section>
        <section className="flex min-h-svh flex-col bg-background px-6 py-8 sm:px-10">
            <div className="flex items-center gap-3 lg:hidden"><div className="flex size-9 items-center justify-center bg-primary text-primary-foreground font-black">L</div><span className="font-bold tracking-tight">LUMIRA</span></div>
            <div className="flex flex-1 items-center justify-center">
                <form onSubmit={submit} className="flex w-full max-w-sm flex-col gap-6">
                    <div><p className="text-sm font-medium text-primary">GET STARTED</p><h2 className="mt-2 text-3xl font-semibold tracking-tight">Create your account</h2><p className="mt-2 text-sm text-muted-foreground">Use your email and a password to secure your designs.</p></div>
                    <div className="flex flex-col gap-4">
                        <label className="flex flex-col gap-2 text-sm font-medium" htmlFor="signup-email">Email<Input id="signup-email" type="email" autoComplete="email" required placeholder="you@example.com" value={email} onChange={lambda (e: ChangeEvent) { email = e.target.value; }} /></label>
                        <label className="flex flex-col gap-2 text-sm font-medium" htmlFor="signup-password">Password<Input id="signup-password" type="password" autoComplete="new-password" minLength={8} required placeholder="At least 8 characters" value={password} onChange={lambda (e: ChangeEvent) { password = e.target.value; }} /></label>
                    </div>
                    {message != "" and <p role="alert" className="text-sm text-destructive">{message}</p>}
                    <Button type="submit" disabled={busy} className="h-11 w-full">{"Creating account..." if busy else "Create account"}</Button>
                    <p className="text-center text-sm text-muted-foreground">Already have an account? <Link to="/login" className="font-medium text-foreground underline underline-offset-4">Sign in</Link></p>
                </form>
            </div>
        </section>
    </div>;
}
