import { Carousel } from "@mantine/carousel";
import { Avatar, Group, Progress, Stack } from "@mantine/core";
import Jazzicon from "@raugfer/jazzicon";
import type { EmblaCarouselType } from "embla-carousel";
import { useEffect, useMemo, useState, type FC } from "react";
import { slice, zeroHash, type Hash } from "viem";
import type { Claim, CycleRange } from "../types";
import { RangeIndicator } from "./RangeIndicator";

interface BisectionProgressProps {
    /**
     * The range being bisected
     */
    range: CycleRange;

    /**
     * Maximum number of bisections to reach the target subdivision
     */
    max: number;

    /**
     * List of bisections. 0 is left, 1 is right
     */
    bisections: (0 | 1)[];

    /**
     * First claim
     */
    claim1: Claim;

    /**
     * Second claim
     */
    claim2: Claim;
}

// builds an image data url for embedding
function buildDataUrl(hash: Hash): string {
    return `data:image/svg+xml;base64,${btoa(Jazzicon(slice(hash, 0, 20)))}`;
}

export const BisectionProgress: FC<BisectionProgressProps> = (props) => {
    const [embla, setEmbla] = useState<EmblaCarouselType | null>(null);
    const { claim1, claim2, range, bisections, max } = props;
    const [domain, setDomain] = useState<CycleRange>(range);

    // create ranges for each bisection
    const ranges = useMemo(
        () =>
            bisections.reduce(
                (r, bisection, i) => {
                    const l = r[i];
                    const [s, e] = l;
                    const mid = Math.floor((s + e) / 2);
                    r.push(bisection === 0 ? [s, mid] : [mid, e]);
                    return r;
                },
                [range],
            ),
        [bisections],
    );

    useEffect(() => {
        if (embla) {
            embla.on("slidesInView", (embla) => {
                const visible = embla.slidesInView();
                if (visible.length > 0) {
                    const top = visible[0];
                    setDomain(ranges[top]);
                }
            });
        }
    }, [embla]);

    return (
        <Stack>
            <Group>
                <Avatar src={buildDataUrl(zeroHash)} size={24} opacity={0} />
                <Stack gap={3}>
                    <RangeIndicator
                        domain={range}
                        value={range}
                        withLabels
                        w={300}
                        h={16}
                    />
                    <Progress value={(bisections.length / max) * 100} />
                </Stack>
            </Group>
            <Carousel
                orientation="vertical"
                slideGap="md"
                height={300}
                slideSize="20%"
                getEmblaApi={setEmbla}
                emblaOptions={{
                    align: "start",
                    inViewThreshold: 1,
                }}
            >
                {ranges.slice(1).map((r, i) => (
                    <Carousel.Slide key={i}>
                        <Group key={i} align="end">
                            <Avatar
                                src={buildDataUrl(
                                    i % 2 === 0 ? claim1.hash : claim2.hash,
                                )}
                                size={24}
                            />
                            <RangeIndicator
                                domain={domain}
                                value={r}
                                withLabels
                                w={300}
                                h={16}
                            />
                        </Group>
                    </Carousel.Slide>
                ))}
            </Carousel>
        </Stack>
    );
};
