. as $layout
| def type_label($id): ($layout.types[$id].label // $id);
{
  storage: [
    .storage[]
    | {
        label,
        slot,
        offset,
        type: type_label(.type)
      }
  ],
  types: (
    [
      .types
      | to_entries[]
      | .value as $type
      | {
          label: $type.label,
          encoding: $type.encoding,
          numberOfBytes: $type.numberOfBytes,
          key: (if $type.key then type_label($type.key) else null end),
          value: (if $type.value then type_label($type.value) else null end),
          members: (
            if $type.members then
              [
                $type.members[]
                | {
                    label,
                    slot,
                    offset,
                    type: type_label(.type)
                  }
              ]
            else null
            end
          )
        }
    ]
    | sort_by(.label)
  )
}
