import { Analytics } from "@vercel/analytics/react";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router";
import App from "./App.tsx";
import "./index.css";
import DataProvider from "./providers/DataProvider.tsx";

createRoot(document.getElementById("root")!).render(
    <StrictMode>
        <BrowserRouter>
            <DataProvider>
                <App />
                <Analytics />
            </DataProvider>
        </BrowserRouter>
    </StrictMode>,
);
