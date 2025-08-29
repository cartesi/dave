import { ScrollArea, Timeline, type TimelineProps } from "@mantine/core";
import {
    Children,
    cloneElement,
    isValidElement,
    useEffect,
    useRef,
    type FC,
} from "react";

export interface ScrollTimelineProps extends TimelineProps {
    onVisibleRangeChange?: (firstVisible: number, lastVisible: number) => void;
}

export const ScrollTimeline: FC<ScrollTimelineProps> = (props) => {
    const { children, h, onVisibleRangeChange, ...timelineProps } = props;

    // refs for the scroll area and timeline items visibility
    const viewportRef = useRef<HTMLDivElement>(null);
    const itemRefs = useRef<(HTMLDivElement | null)[]>([]);

    const updateVisibleIndices = () => {
        if (!viewportRef.current) return;
        const scrollTop = viewportRef.current.scrollTop;
        const viewportHeight = viewportRef.current.clientHeight;

        const visibleIndices = itemRefs.current
            .map((el, idx) => {
                if (!el) return null;
                const itemTop = el.offsetTop;
                const itemBottom = el.offsetTop + el.offsetHeight;

                // partially visible counts
                if (
                    itemBottom > scrollTop &&
                    itemTop < scrollTop + viewportHeight
                ) {
                    return idx;
                }
                return null;
            })
            .filter((idx): idx is number => idx !== null);

        if (visibleIndices.length > 0) {
            const firstVisible = visibleIndices[0];
            const lastVisible = visibleIndices[visibleIndices.length - 1];

            // Notify parent component about visible range changes
            onVisibleRangeChange?.(firstVisible, lastVisible);
        }
    };

    // update visible indices on mount
    useEffect(() => {
        updateVisibleIndices();
    }, []);

    // scroll to bottom on mount
    useEffect(() => {
        if (viewportRef.current) {
            viewportRef.current.scrollTo({
                top: viewportRef.current.scrollHeight,
            });
        }
    }, []);

    // Clone Timeline.Item children and attach refs to them
    const childrenWithRefs = Children.map(children, (child, index) => {
        if (isValidElement(child)) {
            return cloneElement(child, {
                ref: (el: HTMLDivElement | null) => {
                    itemRefs.current[index] = el;
                },
            } as Partial<React.ComponentProps<typeof Timeline.Item>>);
        }
        return child;
    });

    return (
        <ScrollArea
            h={h}
            viewportRef={viewportRef}
            type="auto"
            scrollbars="y"
            onScrollPositionChange={updateVisibleIndices}
        >
            <Timeline {...timelineProps}>{childrenWithRefs}</Timeline>
        </ScrollArea>
    );
};
