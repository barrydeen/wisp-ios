import Foundation

// Minimal pure-Swift secp256k1 implementation for public key derivation only.
// y² = x³ + 7 over F_p, where p = 2²⁵⁶ - 2³² - 977

nonisolated enum Secp256k1 {

    // MARK: - Public API

    static func publicKey(from privateKey: Data) -> Data? {
        guard privateKey.count == 32 else { return nil }
        let k = fromBytes(privateKey)
        guard !feIsZero(k) else { return nil }
        guard let (rx, _) = ecMulG(k) else { return nil }
        return toBytes(rx)
    }

    // MARK: - Field element helpers (4 × UInt64, little-endian limbs)

    private typealias FE = (UInt64, UInt64, UInt64, UInt64)

    private static let P: FE    = (0xFFFFFFFEFFFFFC2F, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF)
    private static let ZERO: FE = (0, 0, 0, 0)
    private static let ONE: FE  = (1, 0, 0, 0)

    private static let Gx: FE = (0x59F2815B16F81798, 0x029BFCDB2DCE28D9, 0x55A06295CE870B07, 0x79BE667EF9DCBBAC)
    private static let Gy: FE = (0x9C47D08FFB10D4B8, 0xFD17B448A6855419, 0x5DA4FBFC0E1108A8, 0x483ADA7726A3C465)

    // MARK: - Byte ↔ limb conversion (big-endian bytes ↔ little-endian limbs)

    private static func fromBytes(_ d: Data) -> FE {
        let b = [UInt8](d)
        func word(_ i: Int) -> UInt64 {
            var w: UInt64 = 0
            for j in 0..<8 { w = (w << 8) | UInt64(b[i * 8 + j]) }
            return w
        }
        return (word(3), word(2), word(1), word(0))
    }

    private static func toBytes(_ a: FE) -> Data {
        var out = [UInt8](repeating: 0, count: 32)
        let words = [a.3, a.2, a.1, a.0]
        for i in 0..<4 {
            var w = words[i]
            for j in stride(from: 7, through: 0, by: -1) {
                out[i * 8 + j] = UInt8(w & 0xFF)
                w >>= 8
            }
        }
        return Data(out)
    }

    // MARK: - 256-bit unsigned comparisons & arithmetic

    private static func feIsZero(_ a: FE) -> Bool {
        a.0 == 0 && a.1 == 0 && a.2 == 0 && a.3 == 0
    }

    private static func feGte(_ a: FE, _ b: FE) -> Bool {
        if a.3 != b.3 { return a.3 > b.3 }
        if a.2 != b.2 { return a.2 > b.2 }
        if a.1 != b.1 { return a.1 > b.1 }
        return a.0 >= b.0
    }

    private static func feAdd(_ a: FE, _ b: FE) -> FE {
        var r: FE = ZERO
        var c: UInt64 = 0
        let s0 = a.0.addingReportingOverflow(b.0);                          r.0 = s0.partialValue; c = s0.overflow ? 1 : 0
        let s1 = a.1.addingReportingOverflow(b.1); let s1c = s1.partialValue.addingReportingOverflow(c); r.1 = s1c.partialValue; c = (s1.overflow ? 1 : 0) &+ (s1c.overflow ? 1 : 0)
        let s2 = a.2.addingReportingOverflow(b.2); let s2c = s2.partialValue.addingReportingOverflow(c); r.2 = s2c.partialValue; c = (s2.overflow ? 1 : 0) &+ (s2c.overflow ? 1 : 0)
        let s3 = a.3.addingReportingOverflow(b.3); let s3c = s3.partialValue.addingReportingOverflow(c); r.3 = s3c.partialValue; c = (s3.overflow ? 1 : 0) &+ (s3c.overflow ? 1 : 0)
        if c > 0 || feGte(r, P) { r = feSub256(r, P) }
        return r
    }

    private static func feSub(_ a: FE, _ b: FE) -> FE {
        if feGte(a, b) { return feSub256(a, b) }
        return feSub256(feAdd256(a, P), b)
    }

    // Raw 256-bit subtraction (a >= b assumed)
    private static func feSub256(_ a: FE, _ b: FE) -> FE {
        var r: FE = ZERO
        var bw: UInt64 = 0
        let d0 = a.0.subtractingReportingOverflow(b.0); let d0b = d0.partialValue.subtractingReportingOverflow(bw); r.0 = d0b.partialValue; bw = (d0.overflow ? 1 : 0) &+ (d0b.overflow ? 1 : 0)
        let d1 = a.1.subtractingReportingOverflow(b.1); let d1b = d1.partialValue.subtractingReportingOverflow(bw); r.1 = d1b.partialValue; bw = (d1.overflow ? 1 : 0) &+ (d1b.overflow ? 1 : 0)
        let d2 = a.2.subtractingReportingOverflow(b.2); let d2b = d2.partialValue.subtractingReportingOverflow(bw); r.2 = d2b.partialValue; bw = (d2.overflow ? 1 : 0) &+ (d2b.overflow ? 1 : 0)
        let d3 = a.3.subtractingReportingOverflow(b.3); let d3b = d3.partialValue.subtractingReportingOverflow(bw); r.3 = d3b.partialValue
        return r
    }

    // Raw 256-bit addition (no mod reduction)
    private static func feAdd256(_ a: FE, _ b: FE) -> FE {
        var r: FE = ZERO
        var c: UInt64 = 0
        let s0 = a.0.addingReportingOverflow(b.0);                          r.0 = s0.partialValue; c = s0.overflow ? 1 : 0
        let s1 = a.1.addingReportingOverflow(b.1); let s1c = s1.partialValue.addingReportingOverflow(c); r.1 = s1c.partialValue; c = (s1.overflow ? 1 : 0) &+ (s1c.overflow ? 1 : 0)
        let s2 = a.2.addingReportingOverflow(b.2); let s2c = s2.partialValue.addingReportingOverflow(c); r.2 = s2c.partialValue; c = (s2.overflow ? 1 : 0) &+ (s2c.overflow ? 1 : 0)
        let s3 = a.3.addingReportingOverflow(b.3); let s3c = s3.partialValue.addingReportingOverflow(c); r.3 = s3c.partialValue
        return r
    }

    // MARK: - Field multiplication with secp256k1-optimised reduction

    private static func feMul(_ a: FE, _ b: FE) -> FE {
        let al = [a.0, a.1, a.2, a.3]
        let bl = [b.0, b.1, b.2, b.3]
        var r = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let (hi, lo) = al[i].multipliedFullWidth(by: bl[j])
                let s1 = r[i+j].addingReportingOverflow(lo)
                let s2 = s1.partialValue.addingReportingOverflow(carry)
                r[i+j] = s2.partialValue
                carry = hi &+ (s1.overflow ? 1 : 0) &+ (s2.overflow ? 1 : 0)
            }
            r[i+4] = carry
        }
        return reduce512(r)
    }

    private static func feSqr(_ a: FE) -> FE { feMul(a, a) }

    // Reduce 512-bit product mod p = 2²⁵⁶ - c, where c = 0x1000003D1
    private static func reduce512(_ r: [UInt64]) -> FE {
        let c: UInt64 = 0x1000003D1

        // high × c + low
        var t0: UInt64 = 0, t1: UInt64 = 0, t2: UInt64 = 0, t3: UInt64 = 0, t4: UInt64 = 0
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (hi, lo) = r[i + 4].multipliedFullWidth(by: c)
            let s = lo.addingReportingOverflow(carry)
            let val = s.partialValue
            carry = hi &+ (s.overflow ? 1 : 0)
            switch i {
            case 0: t0 = val; case 1: t1 = val; case 2: t2 = val; default: t3 = val
            }
        }
        t4 = carry

        // Add low part
        carry = 0
        var a0, a1, a2, a3: UInt64
        let s0 = r[0].addingReportingOverflow(t0); let s0c = s0.partialValue.addingReportingOverflow(carry); a0 = s0c.partialValue; carry = (s0.overflow ? 1:0) &+ (s0c.overflow ? 1:0)
        let s1 = r[1].addingReportingOverflow(t1); let s1c = s1.partialValue.addingReportingOverflow(carry); a1 = s1c.partialValue; carry = (s1.overflow ? 1:0) &+ (s1c.overflow ? 1:0)
        let s2 = r[2].addingReportingOverflow(t2); let s2c = s2.partialValue.addingReportingOverflow(carry); a2 = s2c.partialValue; carry = (s2.overflow ? 1:0) &+ (s2c.overflow ? 1:0)
        let s3 = r[3].addingReportingOverflow(t3); let s3c = s3.partialValue.addingReportingOverflow(carry); a3 = s3c.partialValue; carry = (s3.overflow ? 1:0) &+ (s3c.overflow ? 1:0)
        var overflow = t4 &+ carry

        // Second reduction pass for remaining overflow
        while overflow > 0 {
            let (hi2, lo2) = overflow.multipliedFullWidth(by: c)
            overflow = 0
            var c2: UInt64 = 0
            let q0 = a0.addingReportingOverflow(lo2); let q0c = q0.partialValue.addingReportingOverflow(c2); a0 = q0c.partialValue; c2 = (q0.overflow ? 1:0) &+ (q0c.overflow ? 1:0)
            let q1 = a1.addingReportingOverflow(hi2); let q1c = q1.partialValue.addingReportingOverflow(c2); a1 = q1c.partialValue; c2 = (q1.overflow ? 1:0) &+ (q1c.overflow ? 1:0)
            if c2 > 0 {
                let q2 = a2.addingReportingOverflow(c2); a2 = q2.partialValue; c2 = q2.overflow ? 1 : 0
                if c2 > 0 { let q3 = a3.addingReportingOverflow(c2); a3 = q3.partialValue; overflow = q3.overflow ? 1 : 0 }
            }
        }

        var result: FE = (a0, a1, a2, a3)
        if feGte(result, P) { result = feSub256(result, P) }
        return result
    }

    // a⁻¹ mod p via Fermat: a^(p-2) mod p
    private static func feInv(_ a: FE) -> FE {
        let pMinus2: FE = (0xFFFFFFFEFFFFFC2D, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF)
        return fePow(a, pMinus2)
    }

    private static func fePow(_ base: FE, _ exp: FE) -> FE {
        var result = ONE
        var b = base
        let limbs = [exp.0, exp.1, exp.2, exp.3]
        for i in 0..<4 {
            var word = limbs[i]
            for _ in 0..<64 {
                if word & 1 == 1 { result = feMul(result, b) }
                b = feSqr(b)
                word >>= 1
            }
        }
        return result
    }

    // MARK: - Elliptic curve operations (Jacobian coordinates)
    // Affine (x,y) ↔ Jacobian (X, Y, Z) where x = X/Z², y = Y/Z³

    // Point doubling — dbl-2009-l (a = 0)
    private static func ecDouble(_ X1: FE, _ Y1: FE, _ Z1: FE) -> (FE, FE, FE) {
        if feIsZero(Z1) { return (ZERO, ONE, ZERO) }

        let A = feSqr(X1)
        let B = feSqr(Y1)
        let C = feSqr(B)

        let xpb = feAdd(X1, B)
        let d1 = feSub(feSub(feSqr(xpb), A), C)
        let D = feAdd(d1, d1)

        let E = feAdd(A, feAdd(A, A))   // 3A
        let F = feSqr(E)

        let X3 = feSub(F, feAdd(D, D))

        let c2 = feAdd(C, C)
        let c4 = feAdd(c2, c2)
        let c8 = feAdd(c4, c4)
        let Y3 = feSub(feMul(E, feSub(D, X3)), c8)

        let yz = feMul(Y1, Z1)
        let Z3 = feAdd(yz, yz)

        return (X3, Y3, Z3)
    }

    // Mixed addition: Jacobian (X1,Y1,Z1) + Affine (x2,y2) — madd-2007-bl
    private static func ecAddMixed(_ X1: FE, _ Y1: FE, _ Z1: FE, _ x2: FE, _ y2: FE) -> (FE, FE, FE) {
        if feIsZero(Z1) { return (x2, y2, ONE) }

        let Z1Z1 = feSqr(Z1)
        let U2 = feMul(x2, Z1Z1)
        let S2 = feMul(y2, feMul(Z1, Z1Z1))

        let H = feSub(U2, X1)

        if feIsZero(H) {
            if feIsZero(feSub(S2, Y1)) { return ecDouble(X1, Y1, Z1) }
            return (ZERO, ONE, ZERO)
        }

        let HH = feSqr(H)
        let I = feAdd(feAdd(HH, HH), feAdd(HH, HH))  // 4·HH
        let J = feMul(H, I)

        let s2my1 = feSub(S2, Y1)
        let r = feAdd(s2my1, s2my1)

        let V = feMul(X1, I)
        let X3 = feSub(feSub(feSqr(r), J), feAdd(V, V))

        let y1j = feMul(Y1, J)
        let Y3 = feSub(feMul(r, feSub(V, X3)), feAdd(y1j, y1j))

        let Z3 = feSub(feSub(feSqr(feAdd(Z1, H)), Z1Z1), HH)

        return (X3, Y3, Z3)
    }

    // Scalar multiplication: k × G (double-and-add, left to right)
    private static func ecMulG(_ k: FE) -> (FE, FE)? {
        var rx = ZERO, ry = ONE, rz = ZERO  // infinity

        let limbs = [k.3, k.2, k.1, k.0]  // most-significant limb first
        var started = false
        for limb in limbs {
            for bit in stride(from: 63, through: 0, by: -1) {
                if started {
                    (rx, ry, rz) = ecDouble(rx, ry, rz)
                }
                if (limb >> bit) & 1 == 1 {
                    (rx, ry, rz) = ecAddMixed(rx, ry, rz, Gx, Gy)
                    started = true
                }
            }
        }

        if feIsZero(rz) { return nil }

        let zInv = feInv(rz)
        let zInv2 = feSqr(zInv)
        let zInv3 = feMul(zInv2, zInv)
        return (feMul(rx, zInv2), feMul(ry, zInv3))
    }
}
