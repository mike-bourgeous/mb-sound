RSpec.describe(MB::Sound::BufferHelper, :aggregate_failures) do
  let(:bufhelper) {
    c = Class.new do
      include MB::Sound::BufferHelper

      attr_reader :buf, :tmpbuf

      def setup_buffer(*a, **ka)
        super
      end

      def expand_buffer(*a, **ka)
        super
      end

      def promote_buffer(*a, **ka)
        super
      end
    end

    c.new
  }

  describe '#setup_buffer' do
    shared_examples_for :setup_buffer do
      it 'can create a real float buffer' do
        bufhelper.setup_buffer(length: 5, complex: false, temp: temp, double: false)
        expect(buf).to be_a(Numo::SFloat)
        expect(buf.length).to eq(5)
      end

      it 'can create a real double buffer' do
        bufhelper.setup_buffer(length: 5, complex: false, temp: temp, double: true)
        expect(buf).to be_a(Numo::DFloat)
        expect(buf.length).to eq(5)
      end

      it 'can create a complex float buffer' do
        bufhelper.setup_buffer(length: 5, complex: true, temp: temp, double: false)
        expect(buf).to be_a(Numo::SComplex)
        expect(buf.length).to eq(5)
      end

      it 'can create a complex double buffer' do
        bufhelper.setup_buffer(length: 5, complex: true, temp: temp, double: true)
        expect(buf).to be_a(Numo::DComplex)
        expect(buf.length).to eq(5)
      end

      it 'preserves contents when promoting a float buffer to double' do
        bufhelper.setup_buffer(length: 5, complex: false, temp: temp, double: false)
        expect(buf).to be_a(Numo::SFloat)

        buf[] = Numo::SFloat[1, 2, 3, 4, 5]

        bufhelper.setup_buffer(length: 5, complex: false, temp: temp, double: true)
        expect(buf).to be_a(Numo::DFloat).and eq(Numo::DFloat[1, 2, 3, 4, 5])
      end

      it 'preserves contents when promoting float real to complex' do
        bufhelper.setup_buffer(length: 5, complex: false, temp: temp, double: false)
        expect(buf).to be_a(Numo::SFloat)

        buf[] = Numo::SFloat[1, 2, 3, 4, 5]

        bufhelper.setup_buffer(length: 5, complex: true, temp: temp, double: false)
        expect(buf).to be_a(Numo::SComplex).and eq(Numo::SComplex[1, 2, 3, 4, 5])
      end

      it 'preserves contents when promoting float real to complex double' do
        bufhelper.setup_buffer(length: 5, complex: false, temp: temp, double: false)
        expect(buf).to be_a(Numo::SFloat)

        buf[] = Numo::SFloat[1, 2, 3, 4, 5]

        bufhelper.setup_buffer(length: 5, complex: true, temp: temp, double: true)
        expect(buf).to be_a(Numo::DComplex).and eq(Numo::DComplex[1, 2, 3, 4, 5])
      end

      it 'preserves contents when growing a buffer' do
        bufhelper.setup_buffer(length: 3, complex: false, temp: temp, double: false)
        buf[] = Numo::SFloat[1, -1, 2]
        bufhelper.setup_buffer(length: 5, complex: false, temp: temp, double: false)
        expect(buf).to eq(Numo::SFloat[1, -1, 2, 0, 0])
      end

      it 'preserves contents when shrinking a buffer, as much as possible' do
        bufhelper.setup_buffer(length: 5, complex: false, temp: temp, double: false)
        buf[] = Numo::SFloat[1, 2, 3, 4, 5]
        bufhelper.setup_buffer(length: 2, complex: false, temp: temp, double: false)
        expect(buf).to eq(Numo::SFloat[1, 2])
      end

      it 'can both grow and convert a buffer within a single call, preserving contents' do
        bufhelper.setup_buffer(length: 5, complex: false, temp: temp, double: false)
        buf[] = Numo::SFloat[1,2,3,4,5]

        bufhelper.setup_buffer(length: 6, complex: true, temp: temp, double: false)
        expect(buf).to be_a(Numo::SComplex).and eq(Numo::SComplex[1,2,3,4,5,0])
      end

      it 'can both shrink and convert a buffer within a single call, preserving contents' do
        bufhelper.setup_buffer(length: 5, complex: false, temp: temp, double: false)
        buf[] = Numo::SFloat[1,2,3,4,5]

        bufhelper.setup_buffer(length: 3, complex: true, temp: temp, double: false)
        expect(buf).to be_a(Numo::SComplex).and eq(Numo::SComplex[1,2,3])
      end

      it 'rounds lengths up using .ceil' do
        bufhelper.setup_buffer(length: 7.1, temp: temp)
        expect(buf.length).to eq(8)
      end
    end

    context 'when :temp is false' do
      let(:temp) { false }

      context 'working with @buf' do
        def buf; bufhelper.buf; end
        it_behaves_like :setup_buffer
      end

      it 'does not create a temporary buffer' do
        bufhelper.setup_buffer(length: 3, complex: false, temp: false, double: false)
        expect(bufhelper.tmpbuf).to eq(nil)
      end
    end

    context 'when :temp is true' do
      let(:temp) { true }

      context 'working with @buf' do
        def buf; bufhelper.buf; end
        it_behaves_like :setup_buffer
      end

      context 'working with @tmpbuf' do
        def buf; bufhelper.tmpbuf; end
        it_behaves_like :setup_buffer
      end

      it 'creates a temporary buffer' do
        bufhelper.setup_buffer(length: 3, complex: false, temp: true, double: false)
        expect(bufhelper.tmpbuf).to be_a(Numo::SFloat)
      end
    end

    it 'raises an error when trying to convert from complex to real' do
      bufhelper.setup_buffer(length: 5, complex: true, temp: false, double: false)
      expect {
        bufhelper.setup_buffer(length: 5, complex: false, temp: false, double: false)
      }.to raise_error(Numo::NArray::CastError)
    end
  end

  describe '#expand_buffer' do
    before do
      bufhelper.setup_buffer(length: 6, temp: temp, complex: false, double: false)
      bufhelper.buf[] = Numo::SFloat[1, 2, 3, 4, 5, -6]
      bufhelper.tmpbuf[] = bufhelper.buf if temp
    end

    shared_examples_for :expand_buffer do
      it 'promotes float to double' do
        expect(buf).to be_a(Numo::SFloat)
        bufhelper.expand_buffer(Numo::DFloat[])
        expect(buf).to be_a(Numo::DFloat).and eq(Numo::DFloat[1,2,3,4,5,-6])
      end

      it 'promotes real to complex' do
        expect(buf).to be_a(Numo::SFloat)
        bufhelper.expand_buffer(Numo::SComplex[])
        expect(buf).to be_a(Numo::SComplex).and eq(Numo::SComplex[1,2,3,4,5,-6])
      end

      it 'does not demote double to float' do
        bufhelper.expand_buffer(Numo::DFloat[])
        bufhelper.expand_buffer(Numo::SFloat[])
        expect(buf).to be_a(Numo::DFloat).and eq(Numo::DFloat[1,2,3,4,5,-6])
      end

      it 'does not demote complex to real' do
        expect(buf).to be_a(Numo::SFloat)
        bufhelper.expand_buffer(Numo::DComplex[1,2,3,4,5,6])
        bufhelper.expand_buffer(Numo::DFloat[1,2,3,4,5,6,7])
        expect(buf).to be_a(Numo::DComplex).and eq(Numo::DComplex[1,2,3,4,5,-6,0])
      end

      it 'does not reduce length' do
        bufhelper.expand_buffer(Numo::SFloat[1,2])
        expect(buf.length).to eq(6)
      end

      it 'does not increase length if grow is false' do
        bufhelper.expand_buffer(Numo::SFloat[1,2,3,4,5,6,7,8,9], grow: false)
        expect(buf.length).to eq(6)
      end

      it 'can change length and type together' do
        expect(buf).to be_a(Numo::SFloat)
        bufhelper.expand_buffer(Numo::DComplex[1,2,3,4,5,6,7])
        expect(buf).to be_a(Numo::DComplex).and eq(Numo::DComplex[1,2,3,4,5,-6,0])
      end

      it 'grows the buffer even if the type is already Complex Double' do
        bufhelper.expand_buffer(Numo::DComplex[])
        expect(buf).to be_a(Numo::DComplex)

        bufhelper.expand_buffer(Numo::SFloat.zeros(123))
        expect(buf.length).to eq(123)
      end

      it 'accepts a length override' do
        expect(buf.length).not_to eq(17)
        bufhelper.expand_buffer(Numo::DComplex.zeros(200), length: 17)
        expect(buf.length).to eq(17)
        expect(buf).to be_a(Numo::DComplex)
        expect(buf[0]).to eq(1)
      end

      it 'accepts a complex value override' do
        bufhelper.expand_buffer(Numo::SFloat[], complex: true)
        expect(buf).to be_a(Numo::SComplex)
      end

      it 'accepts a double precision override' do
        bufhelper.expand_buffer(Numo::SFloat[], double: true)
        expect(buf).to be_a(Numo::DFloat)
      end
    end

    context 'when :temp is false' do
      let(:temp) { false }

      context 'working with @buf' do
        def buf; bufhelper.buf; end
        it_behaves_like :expand_buffer
      end

      it 'does not create a temporary buffer' do
        bufhelper.expand_buffer(Numo::DComplex[1,2,3,4,5,6,7,8,9])
        expect(bufhelper.buf).to be_a(Numo::DComplex)
        expect(bufhelper.tmpbuf).to eq(nil)
      end
    end

    context 'when :temp is true' do
      let(:temp) { true }

      context 'working with @buf' do
        def buf; bufhelper.buf; end
        it_behaves_like :expand_buffer
      end

      context 'working with @tmpbuf' do
        def buf; bufhelper.tmpbuf; end
        it_behaves_like :expand_buffer
      end

      it 'creates a temporary buffer' do
        bufhelper.expand_buffer(Numo::DComplex[1,2,3,4,5,6,7,8,9])
        expect(bufhelper.buf).to be_a(Numo::DComplex)
        expect(bufhelper.tmpbuf).to be_a(Numo::DComplex)
      end
    end
  end

  describe '#promote_buffer' do
    before do
      bufhelper.setup_buffer(length: 6, temp: temp, complex: false, double: false)
      bufhelper.buf[] = Numo::SFloat[1, 2, 3, 4, 5, -6]
      bufhelper.tmpbuf[] = bufhelper.buf if temp
    end

    shared_examples_for :promote_buffer do
      it 'can promote to double' do
        bufhelper.promote_buffer(double: true)
        expect(buf).to be_a(Numo::DFloat)
      end

      it 'can promote to complex' do
        bufhelper.promote_buffer(complex: true)
        expect(buf).to be_a(Numo::SComplex)
      end

      it 'can promote to complex double' do
        bufhelper.promote_buffer(complex: true, double: true)
        expect(buf).to be_a(Numo::DComplex)
      end

      it 'can grow the buffer' do
        bufhelper.promote_buffer(length: 123)
        expect(buf.length).to eq(123)
      end

      it 'cannot shrink the buffer' do
        expect { bufhelper.promote_buffer(length: 1) }.not_to change { buf.length }
      end
    end

    context 'when :temp is false' do
      let(:temp) { false }

      it 'can add a temporary buffer if requested' do
        expect(bufhelper.tmpbuf).to eq(nil)
        bufhelper.promote_buffer(temp: true)
        expect(bufhelper.tmpbuf).to be_a(Numo::SFloat)
      end

      it 'does not add a temporary buffer by default' do
        bufhelper.promote_buffer
        expect(bufhelper.tmpbuf).to eq(nil)
      end

      context 'working with @buf' do
        def buf; bufhelper.buf; end
        it_behaves_like :promote_buffer
      end
    end

    context 'when :temp is true' do
      let(:temp) { true }

      context 'working with @buf' do
        def buf; bufhelper.buf; end
        it_behaves_like :promote_buffer
      end

      context 'working with @tmpbuf' do
        def buf; bufhelper.tmpbuf; end
        it_behaves_like :promote_buffer
      end

      it 'preserves and promotes the temporary buffer' do
        expect(bufhelper.tmpbuf).to be_a(Numo::SFloat)
        bufhelper.promote_buffer(complex: true)
        expect(bufhelper.tmpbuf).to be_a(Numo::SComplex)
        bufhelper.promote_buffer(double: true)
        expect(bufhelper.tmpbuf).to be_a(Numo::DComplex)
      end
    end
  end
end
