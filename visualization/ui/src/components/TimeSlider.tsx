import { Slider } from "@mantine/core";
import { fromUnixTime } from "date-fns";
import { useEffect, useState, type FC } from "react";

const dateFormatter = new Intl.DateTimeFormat("en-US", {
    dateStyle: "short",
    timeStyle: "medium",
});

interface TimeSliderProps {
    timestamps: number[];
    onChange: (timestamp: number) => void;
}

export const TimeSlider: FC<TimeSliderProps> = ({ timestamps, onChange }) => {
    const [minTimestamp, setMinTimestamp] = useState(0);
    const [maxTimestamp, setMaxTimestamp] = useState(0);
    const [timeMarks, setTimeMarks] = useState<{ value: number }[]>([]);
    const [now, setNow] = useState(0);

    useEffect(() => {
        if (timestamps.length > 0) {
            console.log("running....");
            // find the minimum and maximum timestamps
            const min = Math.min(...timestamps);
            const max = Math.max(...timestamps);

            // set the state
            setMinTimestamp(min);
            setMaxTimestamp(max);
            setNow(max);

            onChange(max);
            // set slider marks
            setTimeMarks(timestamps.map((value) => ({ value })));
        }
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [timestamps]);

    return (
        <Slider
            defaultValue={maxTimestamp}
            disabled={now === undefined}
            min={minTimestamp}
            max={maxTimestamp}
            marks={timeMarks}
            restrictToMarks
            value={now}
            onChange={(value) => {
                setNow(value);
                onChange(value);
            }}
            w={300}
            label={(value) => dateFormatter.format(fromUnixTime(value))}
        />
    );
};
