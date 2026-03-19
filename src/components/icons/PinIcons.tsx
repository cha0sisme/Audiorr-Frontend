import type { SVGProps } from 'react'

type Props = SVGProps<SVGSVGElement>

const baseProps: Partial<Props> = {
  viewBox: '0 0 24 24',
  fill: 'none',
  xmlns: 'http://www.w3.org/2000/svg',
}

const PIN_BODY_PATH =
  'M14.636 3.91c.653-.436.98-.654 1.335-.618c.356.035.633.312 1.188.867l2.682 2.682c.555.555.832.832.867 1.188c.036.356-.182.682-.617 1.335l-1.65 2.473c-.561.843-.842 1.264-1.066 1.714a8.005 8.005 0 0 0-.427 1.031c-.16.477-.26.974-.458 1.967l-.19.955l-.002.006a1 1 0 0 1-1.547.625l-.005-.004l-.027-.018a35 35 0 0 1-8.85-8.858l-.004-.006a1 1 0 0 1 .625-1.547l.006-.001l.955-.191c.993-.199 1.49-.298 1.967-.458a7.997 7.997 0 0 0 1.03-.427c.45-.224.872-.505 1.715-1.067z'
const PIN_STEM_PATH = 'm5 19l4.5-4.5'

export function PinFilledIcon(props: Props) {
  return (
    <svg {...baseProps} {...props}>
      <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <path fill="currentColor" d={PIN_BODY_PATH} />
        <path d={PIN_STEM_PATH} />
      </g>
    </svg>
  )
}

export function PinOutlinedIcon(props: Props) {
  return (
    <svg {...baseProps} {...props}>
      <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <path d={PIN_BODY_PATH} />
        <path d={PIN_STEM_PATH} />
      </g>
    </svg>
  )
}


