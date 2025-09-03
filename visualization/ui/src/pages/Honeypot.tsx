import type { FC } from "react";
import { Dispute } from "../components/honeypot/Dispute";
import { useClaims } from "../hooks/useClaims";

export const Honeypot: FC = () => {
    const { claims } = useClaims();
    return claims && claims.length > 1 ? (
        <Dispute claims={claims ?? []} eliminatedClaims={[]} />
    ) : null;
};
